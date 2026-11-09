options gen2
options persistent_heap
options gc
require ../runtime.das

def rejects_buffer(blk : block<()>) {
    var rejected = false
    try { invoke(blk) } recover { rejected = true }
    verify(rejected)
}

[export]
def main() {
    var vm <- init_vm()
    var inscope output : array<Val>
    var checked = 0
    // Compare the pointer kernels against an indexed reference for every suffix
    // of small arrays, plus allocator-size boundaries and a larger buffer.
    for (size in [0, 1, 2, 3, 7, 16, 31, 32, 33, 127, 128, 129, 4097]) {
        var inscope source : array<Val>
        for (i in range(size)) { push(source, number(vm, int64(i))) }
        let owner = vector(vm, source)
        var inscope offsets : array<int>
        if (size <= 33) {
            for (start in range(size + 1)) { push(offsets, start) }
        } else {
            offsets <- [0, 1, size / 2, size - 1, size]
        }
        for (start in offsets) {
            let tail = alloc(vm, Data(list_tail = ListTail(owner = owner, start = start)))
            // Prefill a larger destination, then shrink it to the suffix.
            copy_items(vm, owner, output)
            copy_items(vm, tail, output)
            verify(length(output) == size - start)
            for (i in range(length(output))) {
                verify(numeric(vm, output[i]) == int64(start + i))
            }
            var inscope expected := output
            let other = list(vm, expected)
            verify(equal(vm, tail, other) && equal(vm, other, tail))
            if (!empty(output)) {
                // A mismatch at either endpoint must be detected without
                // reading past the interval or changing the shared owner.
                for (at in [0, length(output) - 1]) {
                    var inscope changed := output
                    changed[at] = number(vm, -1l)
                    let unequal = vector(vm, changed)
                    verify(!equal(vm, tail, unequal) && !equal(vm, unequal, tail))
                }
                verify(numeric(vm, nth_item(vm, owner, int64(start))) == int64(start))
            }
            // Reuse the same destination in the opposite direction (grow).
            copy_items(vm, owner, output)
            verify(length(output) == size)
            checked++
        }
        collect(vm)
    }
    let owner = vector(vm, [number(vm, 1l), number(vm, 2l)])
    let other = list(vm, [number(vm, 1l), number(vm, 2l)])
    // Forged internal views must fail at the interval guard, before pointers
    // are dereferenced. Lisp code cannot construct these invalid structures.
    for (bad in [SequenceView(owner = owner, start = -1, count = 1),
                 SequenceView(owner = owner, start = 2, count = 1),
                 SequenceView(owner = owner, start = 3, count = 1),
                 SequenceView(owner = owner, start = 0, count = -1)]) {
        let valid = SequenceView(owner = other, count = bad.count)
        rejects_buffer() { equal_views(vm, bad, valid) }
        rejects_buffer() { equal_views(vm, valid, bad) }
        checked++
    }
    for (start in [-1, 3]) {
        let bad = alloc(vm, Data(list_tail = ListTail(owner = owner, start = start)))
        rejects_buffer() { copy_items(vm, bad, output) }
        checked++
    }
    let tail = rest_list(vm, owner)
    rejects_buffer() { copy_items(vm, tail, vm.values[owner].data as vector) }
    verify(pr_str(vm, owner) == "[1 2]")
    checked++
    print("PASS: {checked} buffer checks (empty, endpoints, reuse, equality and immutability)\n")
}
