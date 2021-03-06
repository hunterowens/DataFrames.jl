immutable ParsedCSV
    bytes::Vector{Uint8} # Raw bytes from CSV file
    bounds::Vector{Int}  # Right field boundary indices
    lines::Vector{Int}   # Line break indices
    quoted::BitVector    # Was field quoted in text
end

immutable ParseOptions{S <: ByteString}
    header::Bool
    separator::Char
    quotemarks::Vector{Char}
    decimal::Char
    nastrings::Vector{S}
    truestrings::Vector{S}
    falsestrings::Vector{S}
    makefactors::Bool
    names::Vector{Symbol}
    eltypes::Vector{DataType}
    allowcomments::Bool
    commentmark::Char
    ignorepadding::Bool
    skipstart::Int
    skiprows::AbstractVector{Int}
    skipblanks::Bool
    encoding::Symbol
    allowescapes::Bool
end

# Dispatch on values of ParseOptions to avoid running
#   unused checks for every byte read
immutable ParseType{ALLOWCOMMENTS, SKIPBLANKS, ALLOWESCAPES, SPC_SEP} end
ParseType(o::ParseOptions) = ParseType{o.allowcomments, o.skipblanks, o.allowescapes, o.separator == ' '}()

macro read_peek_eof(io, nextchr)
    io = esc(io)
    nextchr = esc(nextchr)
    quote
        nextnext = eof($io) ? 0xff : read($io, Uint8)
        $nextchr, nextnext, nextnext == 0xff
    end
end

macro skip_within_eol(io, chr, nextchr, endf)
    io = esc(io)
    chr = esc(chr)
    nextchr = esc(nextchr)
    endf = esc(endf)
    quote
        if $chr == '\r' && $nextchr == '\n'
            $chr, $nextchr, $endf = @read_peek_eof($io, $nextchr)
        end
    end
end

macro skip_to_eol(io, chr, nextchr, endf)
    io = esc(io)
    chr = esc(chr)
    nextchr = esc(nextchr)
    endf = esc(endf)
    quote
        while !$endf && !@atnewline($chr, $nextchr)
            $chr, $nextchr, $endf = @read_peek_eof($io, $nextchr)
        end
        @skip_within_eol($io, $chr, $nextchr, $endf)
    end
end

macro atnewline(chr, nextchr)
    chr = esc(chr)
    nextchr = esc(nextchr)
    quote
        $chr == '\n' || $chr == '\r'
    end
end

macro atblankline(chr, nextchr)
    chr = esc(chr)
    nextchr = esc(nextchr)
    quote
        ($chr == '\n' || $chr == '\r') &&
        ($nextchr == '\n' || $nextchr == '\r')
    end
end

macro atescape(chr, nextchr, quotemarks)
    chr = esc(chr)
    nextchr = esc(nextchr)
    quotemarks = esc(quotemarks)
    quote
        ($chr == '\\' && ($nextchr == '\\' || $nextchr in $quotemarks)) ||
        ($chr == $nextchr && $chr in $quotemarks)
    end
end

macro atcescape(chr, nextchr)
    chr = esc(chr)
    nextchr = esc(nextchr)
    quote
        $chr == '\\' &&
        ($nextchr == 'n' ||
         $nextchr == 't' ||
         $nextchr == 'r' ||
         $nextchr == 'a' ||
         $nextchr == 'b' ||
         $nextchr == 'f' ||
         $nextchr == 'v' ||
         $nextchr == '\\')
    end
end

macro mergechr(chr, nextchr)
    chr = esc(chr)
    nextchr = esc(nextchr)
    quote
        if $chr == '\\'
            if $nextchr == 'n'
                '\n'
            elseif $nextchr == 't'
                '\t'
            elseif $nextchr == 'r'
                '\r'
            elseif $nextchr == 'a'
                '\a'
            elseif $nextchr == 'b'
                '\b'
            elseif $nextchr == 'f'
                '\f'
            elseif $nextchr == 'v'
                '\v'
            elseif $nextchr == '\\'
                '\\'
            else
                msg = @sprintf("Invalid escape character '%s%s' encountered",
                               $chr,
                               $nextchr)
                error(msg)
            end
        else
            msg = @sprintf("Invalid escape character '%s%s' encountered",
                           $chr,
                           $nextchr)
            error(msg)
        end
    end
end

macro isspace(byte)
    byte = esc(byte)
    quote
        0x09 <= $byte <= 0x0d || $byte == 0x20
    end
end

# This trick is ugly, but is ~33% faster than push!() for large arrays
macro push(count, a, val, l)
    count = esc(count) # Number of items in array
    a = esc(a)         # Array to update
    val = esc(val)     # Value to insert
    l = esc(l)         # Length of array
    quote
        $count += 1
        if $l < $count
            $l *= 2
            resize!($a, $l)
        end
        $a[$count] = $val
    end
end

function getseparator(filename::String)
    m = match(r"\.(\w+)(\.(gz|bz|bz2))?$", filename)
    ext = isa(m, RegexMatch) ? m.captures[1] : ""
    if ext == "csv"
        return ','
    elseif ext == "tsv"
        return '\t'
    elseif ext == "wsv"
        return ' '
    else
        return ','
    end
end

tf = (true, false)
for allowcomments in tf, skipblanks in tf, allowescapes in tf, wsv in tf
    dtype = ParseType{allowcomments, skipblanks, allowescapes, wsv}
    @eval begin
        # Read CSV file's rows into buffer while storing field boundary information
        # TODO: Experiment with mmaping input
        function readnrows!(p::ParsedCSV,
                            io::IO,
                            nrows::Integer,
                            o::ParseOptions,
                            dispatcher::$(dtype),
                            firstchr::Uint8=0xff)
            # TODO: Use better variable names
            # Information about parse results
            n_bytes = 0
            n_bounds = 0
            n_lines = 0
            n_fields = 1
            l_bytes = length(p.bytes)
            l_lines = length(p.lines)
            l_bounds = length(p.bounds)
            l_quoted = length(p.quoted)

            # Current state of the parser
            in_quotes = false
            in_escape = false
            $(if allowcomments quote at_start = true end end)
            $(if wsv quote skip_white = true end end)
            chr = 0xff
            nextchr = (firstchr == 0xff && !eof(io)) ? read(io, Uint8) : firstchr
            endf = nextchr == 0xff

            # 'in' does not work if passed Uint8 and Vector{Char}
            quotemarks = convert(Vector{Uint8}, o.quotemarks)

            # Insert a dummy field bound at position 0
            @push(n_bounds, p.bounds, 0, l_bounds)
            @push(n_bytes, p.bytes, '\n', l_bytes)
            @push(n_lines, p.lines, 0, l_lines)

            # Loop over bytes from the input until we've read requested rows
            while !endf && ((nrows == -1) || (n_lines < nrows + 1))

                chr, nextchr, endf = @read_peek_eof(io, nextchr)

                # === Debugging ===
                # if in_quotes
                #     print_with_color(:red, string(char(chr)))
                # else
                #     print_with_color(:green, string(char(chr)))
                # end

                $(if allowcomments
                    quote
                        # Ignore text inside comments completely
                        if !in_quotes && chr == o.commentmark
                            @skip_to_eol(io, chr, nextchr, endf)

                            # Skip the linebreak if the comment began at the start of a line
                            if at_start
                                continue
                            end
                        end
                    end
                end)

                $(if skipblanks
                    quote
                        # Skip blank lines
                        if !in_quotes
                            while !endf && @atblankline(chr, nextchr)
                                chr, nextchr, endf = @read_peek_eof(io, nextchr)
                                @skip_within_eol(io, chr, nextchr, endf)
                            end
                        end
                    end
                end)

                $(if allowescapes
                    quote
                        # Merge chr and nextchr here if they're a c-style escape
                        if @atcescape(chr, nextchr) && !in_escape
                            chr = @mergechr(chr, nextchr)
                            nextchr = eof(io) ? 0xff : read(io, Uint8)
                            endf = nextchr == 0xff
                            in_escape = true
                        end
                    end
                end)

                # No longer at the start of a line that might be a pure comment
                $(if allowcomments quote at_start = false end end)

                # Processing is very different inside and outside of quotes
                if !in_quotes
                    # Entering a quoted region
                    if chr in quotemarks
                        in_quotes = true
                        p.quoted[n_fields] = true
                        $(if wsv quote skip_white = false end end)
                    # Finished reading a field
                    elseif $(if wsv
                                quote chr == ' ' || chr == '\t' end
                            else
                                quote chr == o.separator end
                            end)
                        $(if wsv
                            quote
                                if !(nextchr in [' ', '\t', '\n', '\r']) && !skip_white
                                    @push(n_bounds, p.bounds, n_bytes, l_bounds)
                                    @push(n_bytes, p.bytes, '\n', l_bytes)
                                    @push(n_fields, p.quoted, false, l_quoted)
                                    skip_white = false
                                end
                            end
                        else
                            quote
                                @push(n_bounds, p.bounds, n_bytes, l_bounds)
                                @push(n_bytes, p.bytes, '\n', l_bytes)
                                @push(n_fields, p.quoted, false, l_quoted)
                            end
                        end)
                    # Finished reading a row
                    elseif @atnewline(chr, nextchr)
                        @skip_within_eol(io, chr, nextchr, endf)
                        $(if allowcomments quote at_start = true end end)
                        @push(n_bounds, p.bounds, n_bytes, l_bounds)
                        @push(n_bytes, p.bytes, '\n', l_bytes)
                        @push(n_lines, p.lines, n_bytes, l_lines)
                        @push(n_fields, p.quoted, false, l_quoted)
                        $(if wsv quote skip_white = true end end)
                    # Store character in buffer
                    else
                        @push(n_bytes, p.bytes, chr, l_bytes)
                        $(if wsv quote skip_white = false end end)
                    end
                else
                    # Escape a quotemark inside quoted field
                    if @atescape(chr, nextchr, quotemarks) && !in_escape
                        in_escape = true
                    else
                        # Exit quoted field
                        if chr in quotemarks && !in_escape
                            in_quotes = false
                        # Store character in buffer
                        else
                            @push(n_bytes, p.bytes, chr, l_bytes)
                        end
                        # Escape mode only lasts for one byte
                        in_escape = false
                    end
                end
            end

            # Append a final EOL if it's missing in the raw input
            if endf && !@atnewline(chr, nextchr)
                @push(n_bounds, p.bounds, n_bytes, l_bounds)
                @push(n_bytes, p.bytes, '\n', l_bytes)
                @push(n_lines, p.lines, n_bytes, l_lines)
            end

            # Don't count the dummy boundaries in fields or rows
            return n_bytes, n_bounds - 1, n_lines - 1, nextchr
        end
    end
end

function bytematch{T <: ByteString}(bytes::Vector{Uint8},
                                    left::Integer,
                                    right::Integer,
                                    exemplars::Vector{T})
    l = right - left + 1
    for index in 1:length(exemplars)
        exemplar = exemplars[index]
        if length(exemplar) == l
            matched = true
            for i in 0:(l - 1)
                matched &= bytes[left + i] == exemplar[1 + i]
            end
            if matched
                return true
            end
        end
    end
    return false
end

function bytestotype{N <: Integer,
                     T <: ByteString,
                     P <: ByteString}(::Type{N},
                                      bytes::Vector{Uint8},
                                      left::Integer,
                                      right::Integer,
                                      nastrings::Vector{T},
                                      wasquoted::Bool = false,
                                      truestrings::Vector{P} = P[],
                                      falsestrings::Vector{P} = P[])
    if left > right
        return 0, true, true
    end

    if bytematch(bytes, left, right, nastrings)
        return 0, true, true
    end

    value = 0
    power = 1
    index = right
    byte = bytes[index]

    while index > left
        if '0' <= byte <= '9'
            value += (byte - '0') * power
            power *= 10
        else
            return value, false, false
        end
        index -= 1
        byte = bytes[index]
    end

    if byte == '-'
        return -value, left < right, false
    elseif byte == '+'
        return value, left < right, false
    elseif '0' <= byte <= '9'
        value += (byte - '0') * power
        return value, true, false
    else
        return value, false, false
    end
end

let out = Array(Float64, 1)
    global bytestotype
    function bytestotype{N <: FloatingPoint,
                         T <: ByteString,
                         P <: ByteString}(::Type{N},
                                          bytes::Vector{Uint8},
                                          left::Integer,
                                          right::Integer,
                                          nastrings::Vector{T},
                                          wasquoted::Bool = false,
                                          truestrings::Vector{P} = P[],
                                          falsestrings::Vector{P} = P[])
        if left > right
            return 0.0, true, true
        end

        if bytematch(bytes, left, right, nastrings)
            return 0.0, true, true
        end

        wasparsed = ccall(:jl_substrtod,
                          Int32,
                          (Ptr{Uint8}, Csize_t, Int, Ptr{Float64}),
                          bytes,
                          convert(Csize_t, left - 1),
                          right - left + 1,
                          out) == 0

        return out[1], wasparsed, false
    end
end

function bytestotype{N <: Bool,
                     T <: ByteString,
                     P <: ByteString}(::Type{N},
                                      bytes::Vector{Uint8},
                                      left::Integer,
                                      right::Integer,
                                      nastrings::Vector{T},
                                      wasquoted::Bool = false,
                                      truestrings::Vector{P} = P[],
                                      falsestrings::Vector{P} = P[])
    if left > right
        return false, true, true
    end

    if bytematch(bytes, left, right, nastrings)
        return false, true, true
    end

    if bytematch(bytes, left, right, truestrings)
        return true, true, false
    elseif bytematch(bytes, left, right, falsestrings)
        return false, true, false
    else
        return false, false, false
    end
end

function bytestotype{N <: String,
                     T <: ByteString,
                     P <: ByteString}(::Type{N},
                                      bytes::Vector{Uint8},
                                      left::Integer,
                                      right::Integer,
                                      nastrings::Vector{T},
                                      wasquoted::Bool = false,
                                      truestrings::Vector{P} = P[],
                                      falsestrings::Vector{P} = P[])
    if left > right
        if wasquoted
            return "", true, false
        else
            return "", true, true
        end
    end

    if bytematch(bytes, left, right, nastrings)
        return "", true, true
    end

    return bytestring(bytes[left:right]), true, false
end

function builddf(rows::Integer,
                 cols::Integer,
                 bytes::Integer,
                 fields::Integer,
                 p::ParsedCSV,
                 o::ParseOptions)
    columns = Array(Any, cols)

    for j in 1:cols
        if isempty(o.eltypes)
            values = Array(Int, rows)
        else
            values = Array(o.eltypes[j], rows)
        end

        missing = falses(rows)
        is_int = true
        is_float = true
        is_bool = true

        i = 0
        while i < rows
            i += 1

            # Determine left and right boundaries of field
            left = p.bounds[(i - 1) * cols + j] + 2
            right = p.bounds[(i - 1) * cols + j + 1]
            wasquoted = p.quoted[(i - 1) * cols + j]

            # Ignore left-and-right whitespace padding
            # TODO: Debate moving this into readnrows()
            # TODO: Modify readnrows() so that '\r' and '\n'
            #       don't occur near edges
            if o.ignorepadding && !wasquoted
                while left < right && @isspace(p.bytes[left])
                    left += 1
                end
                while left <= right && @isspace(p.bytes[right])
                    right -= 1
                end
            end

            # If eltypes has been defined, use it
            if !isempty(o.eltypes)
                values[i], wasparsed, missing[i] =
                    bytestotype(o.eltypes[j],
                                p.bytes,
                                left,
                                right,
                                o.nastrings,
                                wasquoted,
                                o.truestrings,
                                o.falsestrings)

                # Don't go to guess type zone
                if wasparsed
                    continue
                else
                    msgio = IOBuffer()
                    @printf(msgio,
                            "Failed to parse '%s' using type '%s'",
                            bytestring(p.bytes[left:right]),
                            o.eltypes[j])
                    error(bytestring(msgio))
                end
            end

            # (1) Try to parse values as Int's
            if is_int
                values[i], wasparsed, missing[i] =
                  bytestotype(Int64,
                              p.bytes,
                              left,
                              right,
                              o.nastrings,
                              wasquoted,
                              o.truestrings,
                              o.falsestrings)
                if wasparsed
                    continue
                else
                    is_int = false
                    values = convert(Array{Float64}, values)
                end
            end

            # (2) Try to parse as Float64's
            if is_float
                values[i], wasparsed, missing[i] =
                  bytestotype(Float64,
                              p.bytes,
                              left,
                              right,
                              o.nastrings,
                              wasquoted,
                              o.truestrings,
                              o.falsestrings)
                if wasparsed
                    continue
                else
                    is_float = false
                    values = Array(Bool, rows)
                    i = 0
                    continue
                end
            end

            # (3) Try to parse as Bool's
            if is_bool
                values[i], wasparsed, missing[i] =
                  bytestotype(Bool,
                              p.bytes,
                              left,
                              right,
                              o.nastrings,
                              wasquoted,
                              o.truestrings,
                              o.falsestrings)
                if wasparsed
                    continue
                else
                    is_bool = false
                    values = Array(UTF8String, rows)
                    i = 0
                    continue
                end
            end

            # (4) Fallback to UTF8String
            values[i], wasparsed, missing[i] =
              bytestotype(UTF8String,
                          p.bytes,
                          left,
                          right,
                          o.nastrings,
                          wasquoted,
                          o.truestrings,
                          o.falsestrings)
        end

        if o.makefactors && !(is_int || is_float || is_bool)
            columns[j] = PooledDataArray(values, missing)
        else
            columns[j] = DataArray(values, missing)
        end
    end

    if isempty(o.names)
        return DataFrame(columns, gennames(cols))
    else
        return DataFrame(columns, o.names)
    end
end

function parsenames!(names::Vector{Symbol},
                     ignorepadding::Bool,
                     bytes::Vector{Uint8},
                     bounds::Vector{Int},
                     quoted::BitVector,
                     fields::Int)
    if fields == 0
        error("Header line was empty")
    end

    resize!(names, fields)

    for j in 1:fields
        left = bounds[j] + 2
        right = bounds[j + 1]

        if ignorepadding && !quoted[j]
            while left < right && @isspace(bytes[left])
                left += 1
            end
            while left <= right && @isspace(bytes[right])
                right -= 1
            end
        end

        names[j] = identifier(bytestring(bytes[left:right]))
    end

    return
end

function findcorruption(rows::Integer,
                        cols::Integer,
                        fields::Integer,
                        p::ParsedCSV)
    n = length(p.bounds)
    lengths = Array(Int, rows)
    t = 1
    for i in 1:rows
        bound = p.lines[i + 1]
        f = 0
        while p.bounds[t] < bound
            f += 1
            t += 1
        end
        lengths[i] = f
    end
    m = median(lengths)
    corruptrows = find(lengths .!= m)
    l = corruptrows[1]
    msgio = IOBuffer()
    @printf(msgio,
            "Saw %d rows, %d columns and %d fields\n",
            rows,
            cols,
            fields)
    @printf(msgio,
            " * Line %d has %d columns\n",
            l,
            lengths[l] + 1)
    error(bytestring(msgio))
end

function readtable!(p::ParsedCSV,
                    io::IO,
                    nrows::Integer,
                    o::ParseOptions)

    chr, nextchr = 0xff, 0xff

    skipped_lines = 0

    # Skip lines at the start
    if o.skipstart != 0
        while skipped_lines < o.skipstart
            chr, nextchr, endf = @read_peek_eof(io, nextchr)
            @skip_to_eol(io, chr, nextchr, endf)
            skipped_lines += 1
        end
    else
        chr, nextchr, endf = @read_peek_eof(io, nextchr)
    end

    if o.allowcomments || o.skipblanks
        while true
            if o.allowcomments && nextchr == o.commentmark
                chr, nextchr, endf = @read_peek_eof(io, nextchr)
                @skip_to_eol(io, chr, nextchr, endf)
            elseif o.skipblanks && @atnewline(nextchr, nextchr)
                chr, nextchr, endf = @read_peek_eof(io, nextchr)
                @skip_within_eol(io, chr, nextchr, endf)
            else
                break
            end
            skipped_lines += 1
        end
    end

    # Use ParseOptions to pick the right method of readnrows!
    d = ParseType(o)

    # Extract the header
    if o.header
        bytes, fields, rows, nextchr = readnrows!(p, io, int64(1), o, d, nextchr)

        # Insert column names from header if none present
        if isempty(o.names)
            parsenames!(o.names, o.ignorepadding, p.bytes, p.bounds, p.quoted, fields)
        end
    end

    # Parse main data set
    bytes, fields, rows, nextchr = readnrows!(p, io, int64(nrows), o, d, nextchr)

    # Sanity checks
    bytes != 0 || error("Failed to read any bytes.")
    rows != 0 || error("Failed to read any rows.")
    fields != 0 || error("Failed to read any fields.")

    # Determine the number of columns
    cols = fld(fields, rows)

    # Confirm that the number of columns is consistent across rows
    if fields != rows * cols
        findcorruption(rows, cols, fields, p)
    end

    # Parse contents of a buffer into a DataFrame
    df = builddf(rows, cols, bytes, fields, p, o)

    # Return the final DataFrame
    return df
end

function readtable(io::IO,
                   nbytes::Integer = 1;
                   header::Bool = true,
                   separator::Char = ',',
                   quotemark::Vector{Char} = ['"'],
                   decimal::Char = '.',
                   nastrings::Vector = ASCIIString["", "NA"],
                   truestrings::Vector = ASCIIString["T", "t", "TRUE", "true"],
                   falsestrings::Vector = ASCIIString["F", "f", "FALSE", "false"],
                   makefactors::Bool = false,
                   nrows::Integer = -1,
                   names::Vector = Symbol[],
                   colnames::Vector = Symbol[],
                   cleannames::Any = nothing,
                   eltypes::Vector{DataType} = DataType[],
                   coltypes::Vector{DataType} = DataType[],
                   allowcomments::Bool = false,
                   commentmark::Char = '#',
                   ignorepadding::Bool = true,
                   skipstart::Integer = 0,
                   skiprows::AbstractVector{Int} = Int[],
                   skipblanks::Bool = true,
                   encoding::Symbol = :utf8,
                   allowescapes::Bool = false)
    if encoding != :utf8
        throw(ArgumentError("Argument 'encoding' only supports ':utf8' currently."))
    elseif !isempty(skiprows)
        throw(ArgumentError("Argument 'skiprows' is not yet supported."))
    elseif decimal != '.'
        throw(ArgumentError("Argument 'decimal' is not yet supported."))
    end

    if !isempty(colnames)
        warn("Argument 'colnames' is deprecated, please use 'names'.")
        if !isempty(names)
            throw(ArgumentError("'names' and 'colnames' can't both be specified."))
        end
        names = colnames
    end
    if !isempty(coltypes)
        warn("Argument 'coltypes' is deprecated, please use 'eltypes'.")
        if !isempty(eltypes)
            throw(ArgumentError("'eltypes' and 'coltypes' can't both be specified."))
        end
        eltypes = coltypes
    end
    if !isa(cleannames, Nothing)
        warn("Argument 'cleannames' is deprecated (it now happens automatically).")
    end

    if !isempty(eltypes)
        for j in 1:length(eltypes)
            if !(eltypes[j] in [UTF8String, Bool, Float64, Int64])
                msgio = IOBuffer()
                @printf(msgio,
                        "Invalid eltype '%s' encountered.\n",
                        eltypes[j])
                @printf(msgio,
                        "Valid eltypes: UTF8String, Bool, Float64 or Int64")
                error(bytestring(msgio))
            end
        end
    end

    # Allocate buffers for storing metadata
    p = ParsedCSV(Array(Uint8, nbytes),
                  Array(Int, 1),
                  Array(Int, 1),
                  BitArray(1))

    # Set parsing options
    o = ParseOptions(header, separator, quotemark, decimal,
                     nastrings, truestrings, falsestrings,
                     makefactors, names, eltypes,
                     allowcomments, commentmark, ignorepadding,
                     skipstart, skiprows, skipblanks, encoding,
                     allowescapes)

    # Use the IO stream method for readtable()
    df = readtable!(p, io, nrows, o)

    # Close the IO stream
    close(io)

    # Return the resulting DataFrame
    return df
end

function readtable(pathname::String;
                   header::Bool = true,
                   separator::Char = getseparator(pathname),
                   quotemark::Vector{Char} = ['"'],
                   decimal::Char = '.',
                   nastrings::Vector = ASCIIString["", "NA"],
                   truestrings::Vector = ASCIIString["T", "t", "TRUE", "true"],
                   falsestrings::Vector = ASCIIString["F", "f", "FALSE", "false"],
                   makefactors::Bool = false,
                   nrows::Integer = -1,
                   names::Vector = Symbol[],
                   colnames::Vector = Symbol[],
                   cleannames::Any = nothing,
                   coltypes::Vector{DataType} = DataType[],
                   eltypes::Vector{DataType} = DataType[],
                   allowcomments::Bool = false,
                   commentmark::Char = '#',
                   ignorepadding::Bool = true,
                   skipstart::Integer = 0,
                   skiprows::AbstractVector{Int} = Int[],
                   skipblanks::Bool = true,
                   encoding::Symbol = :utf8,
                   allowescapes::Bool = false)
    if !isempty(colnames)
        warn("Argument 'colnames' is deprecated, please use 'names'.")
        if !isempty(names)
            throw(ArgumentError("'names' and 'colnames' can't both be specified."))
        end
        names = colnames
    end
    if !isempty(coltypes)
        warn("Argument 'coltypes' is deprecated, please use 'eltypes'.")
        if !isempty(eltypes)
            throw(ArgumentError("'eltypes' and 'coltypes' can't both be specified."))
        end
        eltypes = coltypes
    end
    if !isa(cleannames, Nothing)
        warn("Argument 'cleannames' is deprecated (it now happens automatically).")
    end

    # Open an IO stream based on pathname
    # (1) Path is an HTTP or FTP URL
    if beginswith(pathname, "http://") || beginswith(pathname, "ftp://")
        error("URL retrieval not yet implemented")
    # (2) Path is GZip file
    elseif endswith(pathname, ".gz")
        io = gzopen(pathname, "r")
        nbytes = 2 * filesize(pathname)
    # (3) Path is BZip2 file
    elseif endswith(pathname, ".bz") || endswith(pathname, ".bz2")
        error("BZip2 decompression not yet implemented")
    # (4) Path is an uncompressed file
    else
        io = open(pathname, "r")
        nbytes = filesize(pathname)
    end

    return readtable(io,
                     nbytes,
                     header = header,
                     separator = separator,
                     quotemark = quotemark,
                     decimal = decimal,
                     nastrings = nastrings,
                     truestrings = truestrings,
                     falsestrings = falsestrings,
                     makefactors = makefactors,
                     nrows = nrows,
                     names = names,
                     eltypes = eltypes,
                     allowcomments = allowcomments,
                     commentmark = commentmark,
                     ignorepadding = ignorepadding,
                     skipstart = skipstart,
                     skiprows = skiprows,
                     skipblanks = skipblanks,
                     encoding = encoding,
                     allowescapes = allowescapes)
end

function filldf!(df::DataFrame,
                 rows::Integer,
                 cols::Integer,
                 bytes::Integer,
                 fields::Integer,
                 p::ParsedCSV,
                 o::ParseOptions)
    etypes = eltypes(df)

    if rows != size(df, 1)
        for j in 1:cols
            resize!(df.columns[j].data, rows)
            resize!(df.columns[j].na, rows)
        end
    end

    for j in 1:cols
        c = df.columns[j]
        T = etypes[j]

        i = 0
        while i < rows
            i += 1

            # Determine left and right boundaries of field
            left = p.bounds[(i - 1) * cols + j] + 2
            right = p.bounds[(i - 1) * cols + j + 1]
            wasquoted = p.quoted[(i - 1) * cols + j]

            # Ignore left-and-right whitespace padding
            # TODO: Debate moving this into readnrows()
            # TODO: Modify readnrows() so that '\r' and '\n'
            #       don't occur near edges
            if o.ignorepadding && !wasquoted
                while left < right && @isspace(p.bytes[left])
                    left += 1
                end
                while left <= right && @isspace(p.bytes[right])
                    right -= 1
                end
            end

            # NB: Assumes perfect type stability
            # Use subtypes here
            if !(T in [Int, Float64, Bool, UTF8String])
                error("Invalid eltype encountered")
            end
            c.data[i], wasparsed, c.na[i] =
              bytestotype(T,
                          p.bytes,
                          left,
                          right,
                          o.nastrings,
                          wasquoted,
                          o.truestrings,
                          o.falsestrings)

            if !wasparsed
                error("Failed to parse entry")
            end
        end
    end

    return
end

##############################################################################
#
# Text output
#
##############################################################################

function escapedprint(io::IO, x::Any, escapes::String)
    print(io, x)
end

function escapedprint(io::IO, x::String, escapes::String)
    print_escaped(io, x, escapes)
end

function printtable(io::IO,
                    df::DataFrame;
                    header::Bool = true,
                    separator::Char = ',',
                    quotemark::Char = '"')
    n, p = size(df)
    etypes = eltypes(df)
    if header
        cnames = names(df)
        for j in 1:p
            print(io, quotemark)
            print(io, cnames[j])
            print(io, quotemark)
            if j < p
                print(io, separator)
            else
                print(io, '\n')
            end
        end
    end
    for i in 1:n
        for j in 1:p
            if ! (etypes[j] <: Real)
                print(io, quotemark)
                escapedprint(io, df[i, j], "\"'")
                print(io, quotemark)
            else
                print(io, df[i, j])
            end
            if j < p
                print(io, separator)
            else
                print(io, '\n')
            end
        end
    end
    return
end

function printtable(df::DataFrame;
                    header::Bool = true,
                    separator::Char = ',',
                    quotemark::Char = '"')
    printtable(STDOUT,
               df,
               separator = separator,
               quotemark = quotemark,
               header = header)
    return
end

# Infer configuration settings from filename
function writetable(filename::String,
                    df::DataFrame;
                    header::Bool = true,
                    separator::Char = getseparator(filename),
                    quotemark::Char = '"')
    if endswith(filename, ".gz")
        io = gzopen(filename, "w")
    elseif endswith(filename, ".bz") || endswith(filename, ".bz2")
        error("BZip2 compression not yet implemented")
    else
        io = open(filename, "w")
    end
    printtable(io,
               df,
               separator = separator,
               quotemark = quotemark,
               header = header)
    close(io)
    return
end

##############################################################################
#
# HTML output
#
##############################################################################
function html_escape(cell::String)
    cell = replace(cell, "&", "&amp;")
    cell = replace(cell, "<", "&lt;")
    cell = replace(cell, ">", "&gt;")
    return cell
end

function Base.writemime(io::IO,
                        ::MIME"text/html",
                        df::DataFrame)
    n = size(df, 1)
    cnames = names(df)
    write(io, "<table class=\"data-frame\">")
    write(io, "<tr>")
    write(io, "<th></th>")
    for column_name in cnames
        write(io, "<th>$column_name</th>")
    end
    write(io, "</tr>")
    tty_rows, tty_cols = Base.tty_size()
    for row in 1:min(n, tty_rows)
        write(io, "<tr>")
        write(io, "<th>$row</th>")
        for column_name in cnames
            cell = string(df[row, column_name])
            write(io, "<td>$(html_escape(cell))</td>")
        end
        write(io, "</tr>")
    end
    if n > 20
        write(io, "<tr>")
        write(io, "<th>&vellip;</th>")
        for column_name in cnames
            write(io, "<td>&vellip;</td>")
        end
        write(io, "</tr>")
    end
    write(io, "</table>")
end

##############################################################################
#
# Binary serialization
#
##############################################################################

function save(filename::String, df::AbstractDataFrame)
    f = open(filename, "w")
    serialize(f, df)
    close(f)
    return
end

function loaddf(filename::String)
    f = open(filename)
    dd = deserialize(f)
    close(f)
    return dd
end

# MIME

function Base.writemime(io::IO,
                        ::MIME"text/csv",
                        df::DataFrame)
    printtable(io, df, true, ',')
end

function Base.writemime(io::IO,
                        ::MIME"text/tab-separated-values",
                        df::DataFrame)
    printtable(io, df, true, '\t')
end
