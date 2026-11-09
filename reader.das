options gen2
options strict_smart_pointers = true
options no_unused_block_arguments = false
module reader
require types public
require peg/peg

// dasPEG actions are generated functions. Build an owning syntax tree, then
// lower it into the VM only after a successful parse.
variant SyntaxData {
    token : string
    string_ : string
    list : array<Syntax?>
    vector : array<Syntax?>
    map_ : array<Syntax?>
}
struct Syntax { data : SyntaxData }
struct Parsed { valid : bool; forms : array<Syntax?> }

def prefix(name : string; var x : Syntax? implicit) : Syntax? {
    var xs <- [new Syntax(data <- SyntaxData(token = name)), x]
    return new Syntax(data <- SyntaxData(list <- xs))
}

// Complete recursive grammar, including comments and reader macros.
def parse_forms(input : string;
                blk : block<(var parsed : Parsed# implicit; errors : array<ParsingError>) : void>) {
    parse(input) {
        var program : Parsed
        rule(space, *form as forms, EOF) { return <- Parsed(valid = true, forms <- forms) }
        var form : Syntax?
        rule("(", space, *form as xs, ")", space) { return new Syntax(data <- SyntaxData(list <- xs)) }
        rule("[", space, *form as xs, "]", space) { return new Syntax(data <- SyntaxData(vector <- xs)) }
        rule("\{", space, *form as xs, "\}", space) { return new Syntax(data <- SyntaxData(map_ <- xs)) }
        rule("~@", space, form as x) { return prefix("splice-unquote", x) }
        rule("'", space, form as x) { return prefix("quote", x) }
        rule("`", space, form as x) { return prefix("quasiquote", x) }
        rule("~", space, form as x) { return prefix("unquote", x) }
        rule("@", space, form as x) { return prefix("deref", x) }
        rule("^", space, form as m, form as x) {
            var xs <- [new Syntax(data <- SyntaxData(token = "with-meta")), x, m]
            return new Syntax(data <- SyntaxData(list <- xs))
        }
        rule("\"", *string_char as chars, "\"", space) {
            return new Syntax(data <- SyntaxData(string_ = join(chars, "")))
        }
        rule("{atom_token}" as token, space) { return new Syntax(data <- SyntaxData(token = token)) }
        var string_char : string
        rule("\\n") { return "\n" }
        rule("\\\"") { return "\"" }
        rule("\\\\") { return "\\" }
        rule("\\", "{any}" as c) { return "\\{c}" }
        rule(!set('"', '\\'), "{any}" as c) { return c }
        // Lexical rules carry no syntax node. A bool marker also avoids
        // C++ AOT erasing void? and Syntax? specializations to one helper.
        var atom_token : bool
        rule(token_head, *token_char) { return true }
        var token_head : bool
        // 11 is vertical tab (daScript has no \v character escape).
        rule(!set(' ', '\t', '\r', '\n', '\f', 11, ',', '(', ')', '[', ']', '{', '}', '"', ';', '\'', '`', '~', '^', '@'), any) { return true }
        var token_char : bool
        rule(!set(' ', '\t', '\r', '\n', '\f', 11, ',', '(', ')', '[', ']', '{', '}', '"', ';', '\'', '`'), any) { return true }
        var space : bool
        rule(*ignored) { return true }
        var ignored : bool
        rule(set(' ', '\t', '\r', '\n', '\f', 11, ',')) { return true }
        rule(";", *comment_char) { return true }
        var comment_char : bool
        rule(!set('\r', '\n'), any) { return true }
    }
}

def read_token(var vm : VM; token : string) : Val {
    if (token == "nil") return NIL
    if (token == "true") return TRUE
    if (token == "false") return FALSE
    if (starts_with(token, ":")) return keyword(vm, slice(token, 1))
    let negative = starts_with(token, "-")
    let digits = negative ? slice(token, 1) : token
    var numeric = !empty(digits)
    for (c in each(digits)) { numeric = numeric && c >= '0' && c <= '9' }
    if (!numeric) return symbol(vm, token)
    var magnitude = 0ul
    let limit = negative ? 9223372036854775808ul : 9223372036854775807ul
    for (c in each(digits)) {
        let digit = uint64(c - '0')
        if (magnitude > (limit - digit) / 10ul) return fail(vm, "integer out of int64 range")
        magnitude = magnitude * 10ul + digit
    }
    return number(vm, negative ? int64(0ul - magnitude) : int64(magnitude))
}

def lower(var vm : VM; node : Syntax const? implicit) : Val {
    match (node.data) {
        SyntaxData(token = s) => $ { return read_token(vm, s) }
        SyntaxData(string_ = s) => $ { return text(vm, s) }
        SyntaxData(list = xs) => $ {
            var inscope values <- select(xs) $(x : Syntax const? implicit) { return lower(vm, x) }
            return list(vm, values)
        }
        SyntaxData(vector = xs) => $ {
            var inscope values <- select(xs) $(x : Syntax const? implicit) { return lower(vm, x) }
            return vector(vm, values)
        }
        SyntaxData(map_ = xs) => $ {
            var inscope values <- select(xs) $(x : Syntax const? implicit) { return lower(vm, x) }
            return make_map(vm, values)
        }
    }
    return NIL
}

def read_all(var vm : VM; input : string) : array<Val> {
    var inscope result : array<Val>
    parse_forms(input) $(var parsed; errors) {
        if (!parsed.valid) {
            let detail = empty(errors) ? "unbalanced delimiter, string, or reader macro" : "{errors[0].text} at byte {errors[0].index}"
            fail(vm, "reader: {detail}")
        } else {
            for (node in parsed.forms) { push(result, lower(vm, node)) }
        }
    }
    return <- result
}

def read_str(var vm : VM; input : string) : Val {
    var inscope forms <- read_all(vm, input)
    if (vm.thrown >= 0 || empty(forms)) return NIL
    if (length(forms) != 1) return fail(vm, "read-string expects exactly one form")
    return forms[0]
}
