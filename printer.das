options gen2
module printer
require types public

def escaped(s : string) : string => "\"{replace(replace(replace(s, "\\", "\\\\"), "\"", "\\\""), "\n", "\\n")}\""

def pr_str(vm : VM; v : Val; readable : bool = true; depth : int = 0) : string {
    if (depth > 128) return "#<cycle-or-depth-limit>"
    match (vm.values[v].data) {
        Data(nil_) => $ { return "nil" }
        Data(boolean = b) => $ { return b ? "true" : "false" }
        Data(number = n) => $ { return "{n}" }
        Data(symbol = s) => $ { return s }
        Data(keyword = s) => $ { return ":{s}" }
        Data(text = s) => $ { return readable ? escaped(s) : s }
        Data(list = xs) => $ {
            let body = join(xs, " ") $(var writer; x) {
                write(writer, pr_str(vm, x, readable, depth + 1))
            }
            return "({body})"
        }
        Data(list_tail = _) => $ {
            let view = sequence_view(vm, v)
            let body = build_string() $(var writer) {
                for (i in range(view.count)) {
                    if (i != 0) { write(writer, " ") }
                    write(writer, pr_str(vm, sequence_at(vm, view, i), readable, depth + 1))
                }
            }
            return "({body})"
        }
        Data(vector = xs) => $ {
            let body = join(xs, " ") $(var writer; x) {
                write(writer, pr_str(vm, x, readable, depth + 1))
            }
            return "[{body}]"
        }
        Data(map_ = entries) => $ {
            let body = build_string() $(var writer) {
                var first = true
                for (k, x in keys(entries), values(entries)) {
                    if (!first) { write(writer, " ") }
                    first = false
                    write(writer, starts_with(k, "s") ? (readable ? escaped(slice(k, 1)) : slice(k, 1)) : ":{slice(k, 1)}")
                    write(writer, " ")
                    write(writer, pr_str(vm, x, readable, depth + 1))
                }
            }
            return "\{{body}\}"
        }
        Data(native = name) => $ { return "#<native:{name.name}>" }
        Data(function_ = f) => $ { return f.macro_ ? "#<macro>" : "#<function>" }
        Data(atom = x) => $ { return "(atom {pr_str(vm, x, readable, depth + 1)})" }
    }
    return "#<invalid>"
}
