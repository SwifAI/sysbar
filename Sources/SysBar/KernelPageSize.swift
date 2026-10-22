// Mach exposes this startup-initialized value as a mutable C global. Keep the
// legacy concurrency annotation scoped to this single import and publish only
// an immutable Swift snapshot to collectors.
@preconcurrency import var Darwin.vm_kernel_page_size

/// vm_statistics64 uses kernel pages, which can differ from getpagesize() in
/// a translated Rosetta process. Preserve that unit instead of the task page size.
let kernelPageSize = UInt64(vm_kernel_page_size)
