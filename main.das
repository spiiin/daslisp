options gen2
options stack = 16777216
options persistent_heap
options gc
require runtime
require memory
require daslib/clargs
require daslib/fio

def report(var vm : VM; value : Val) : bool {
    if (vm.thrown >= 0) {
        print("Error: {pr_str(vm, vm.thrown, false)}\n")
        vm.thrown = -1
        return false
    }
    print("{pr_str(vm, value)}\n")
    return true
}

[export, no_jit]
def main() : int {
    var vm <- init_vm()
    init_core(vm)
    if (vm.thrown >= 0) { report(vm, NIL); return 1 }
    let args <- get_user_args()
    if (!empty(args) && args[0] == "--eval") {
        if (length(args) != 2) { print("Usage: --eval expression\n"); return 1 }
        let value = rep(vm, args[1])
        return report(vm, value) ? 0 : 1
    }
    let reader_mode = !empty(args) && (args[0] == "--read" || args[0] == "--reader")
    let batch = (!empty(args) && args[0] == "--read") || (!empty(args) && args[0] == "--batch")
    if (!empty(args) && !batch && !reader_mode) {
        let argv <- skip(args, 1)
        var values <- select(argv) $(s : string) { return text(vm, s) }
        let argv_value = list(vm, values)
        set_binding(vm, 0, "*ARGV*", argv_value)
        let path = text(vm, args[0])
        apply(vm, lookup(vm, 0, "load-file"), [path])
        if (vm.thrown >= 0) { report(vm, NIL); return 1 }
        return 0
    }
    if (!batch) { print("Mal [daScript]\n") }
    while (true) {
        if (!batch) { print("user> "); fflush(fstdout()) }
        let line = read_line(fstdin())
        if (line is none) { break }
        var inscope forms <- read_all(vm, unwrap(line))
        let value_mark = length(vm.root_values)
        push(vm.root_values, forms)
        if (vm.thrown >= 0) { report(vm, NIL) }
        else {
            for (form in forms) {
                let value = reader_mode ? form : eval(vm, form)
                if (!report(vm, value)) { break }
            }
        }
        resize(vm.root_values, value_mark)
        collect(vm)
        unsafe { heap_collect(true, false) }
        fflush(fstdout())
    }
    return 0
}
