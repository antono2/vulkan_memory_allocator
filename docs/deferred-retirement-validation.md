# Deferred upload retirement integration fixture

This branch demonstrates a candidate integration for
[memory PR #34](https://github.com/antono2/memory/pull/34). It is ready for review
with that source revision in an isolated module overlay. The released allocator
still declares `antono2.memory@v1.4.0`; the candidate example must not be merged
or advertised as working with that release. Update the dependency and tested
manifest together after the new memory API is released.

Allocator baseline: `b85f1ec7f29d3eb0442bff57e5cc3b1ee2ea7a26`.
Memory candidate: `8b2c2d8a59e2bb1cbb60b87a4e6212861f422f72`.
Vulkan dependency: `a8ca830921ca77a6826f5040054b7c330f2dfa06` (`v3.2.2`).

`examples/buffer_suballocation/deferred_uploads.v` uses the existing example's
device and allocator. It registers upload slices in a two-entry retirement queue,
submits real buffer copies, observes Vulkan fences before reporting completion,
and releases slices in allocation order. A rejected full-queue registration
leaves upload accounting unchanged. After observing the first fence, another
allocation wraps to offset zero. A final fence and transfer-to-host barriers
permit independent mapped readback of values `21,22,23` before shutdown.

The example performs no premature reuse even if the GPU finishes before the
application polls. Cleanup waits for actual device completion before draining
and destroying pending resources. Device-loss recovery was not fault-injected.
The existing example uses queue family zero; the tested devices provide a usable
transfer-capable queue there. The helper accepts the created queue family index.

## Verified locally

- Official released V 0.5.2 (`7647ce1`), Lavapipe, validation layer enabled: pass.
- Official released V 0.5.2, NVIDIA GeForce GTX 1060, validation layer enabled: pass.
- Pinned V `efae23e` with explicit V3, Lavapipe, validation layer enabled: pass.
- Output: `fenced retirement: copies=3 readback=21,22,23 wrap=0 pending=0`.
- No validation-layer errors were reported by these runs.

The two existing instance/device descriptor locals are mutable for compatibility
with the pinned V3 compiler's pointer checking. No public UploadRing API changes
are required. This is Linux device evidence, not native Windows/macOS coverage.

Reproduce with an overlay containing this allocator, candidate memory and Vulkan:

```sh
export VMODULES=${VMODULES:?Set VMODULES to the isolated module directory}
compiler=${VEXE:-v}
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
  "$compiler" run examples/buffer_suballocation
```

Use the pinned current compiler and add `-new-compiler` for the strict V3 run.
To select a specific driver, set `VK_DRIVER_FILES` to an installed ICD manifest
on the current host. Otherwise the Vulkan loader selects the available driver.
