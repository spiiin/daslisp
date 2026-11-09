options gen2
module line_input
require daslib/fio public
require daslib/option public
require daslib/strings_boost

// fgets returns chunks, not necessarily a whole line. Keep the terminator so
// an empty line is distinct from EOF and the reader sees the original input.
def read_line(stream : file) : Option<string> {
    let line = build_string() $(var writer) {
        while (true) {
            let chunk = fgets(stream)
            write(writer, chunk)
            if (chunk == "" || ends_with(chunk, "\n") || feof(stream)) { break }
        }
    }
    return empty(line) ? none(type<string>) : some(line)
}
