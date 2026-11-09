options gen2
module memory
require types public
require math
require daslib/defer

// Pin externally held handles while a callback evaluates Lisp and may collect.
def with_roots(var vm : VM; roots : array<Val>;
               blk : block<() : Val>) : Val {
    let mark = length(vm.root_values)
    push(vm.root_values, roots)
    defer() { resize(vm.root_values, mark) }
    return invoke(blk)
}

// The evaluator records its live handles explicitly. Embedders pass any
// additional live values as roots when collecting outside evaluation.
def collect(var vm : VM; roots : array<Val> implicit = array<Val>()) {
    var inscope value_work <- [NIL, FALSE, TRUE]
    push(value_work, roots)
    push(value_work, vm.root_values)
    push(value_work, vm.debug_symbol)
    if (vm.thrown >= 0) { push(value_work, vm.thrown) }
    var inscope env_work <- [0]
    push(env_work, vm.root_envs)
    while (!empty(value_work) || !empty(env_work)) {
        while (!empty(value_work)) {
            let id = back(value_work)
            pop(value_work)
            if (vm.values[id].marked) { continue }
            vm.values[id].marked = true
            push(value_work, vm.values[id].meta)
            match (vm.values[id].data) {
                Data(list = xs) | Data(vector = xs) => $ { push(value_work, xs) }
                Data(list_tail = tail) => $ { push(value_work, tail.owner) }
                Data(map_ = entries) => $ { for (v in values(entries)) { push(value_work, v) } }
                Data(function_ = f) => $ {
                    push(value_work, f.params)
                    push(value_work, f.body)
                    push(env_work, f.env)
                }
                Data(atom = v) => $ { push(value_work, v) }
                _ => $ {}
            }
        }
        while (!empty(env_work)) {
            let id = back(env_work)
            pop(env_work)
            if (id < 0 || vm.envs[id].marked) { continue }
            vm.envs[id].marked = true
            push(env_work, vm.envs[id].outer)
            for (k, v in keys(vm.envs[id].bindings), values(vm.envs[id].bindings)) {
                push(value_work, k)
                push(value_work, v)
            }
        }
    }
    for (id in range(length(vm.values))) {
        if (!vm.values[id].live) { continue }
        if (!vm.values[id].marked) {
            if (vm.values[id].data is symbol) {
                erase(vm.symbols, vm.values[id].data as symbol)
            }
            delete vm.values[id]
            vm.values[id] <- Cell(data = Data(nil_), live = false)
            push(vm.free_values, id)
        } else { vm.values[id].marked = false }
    }
    for (id in range(length(vm.envs))) {
        if (!vm.envs[id].live) { continue }
        if (!vm.envs[id].marked) {
            delete vm.envs[id]
            vm.envs[id] <- Env(live = false)
            push(vm.free_envs, id)
        } else { vm.envs[id].marked = false }
    }
    vm.allocations_since_gc = 0
    vm.gc_threshold = max(vm.gc_min_interval, (length(vm.values) - length(vm.free_values)) * 2)
    vm.collections++
}

