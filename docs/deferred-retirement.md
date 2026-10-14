# Fenced upload retirement

This example uses `antono2.memory@v1.5.0` and the Vulkan dependency pinned in
`v.mod` and `compatibility.json`. Install the declared dependencies with the
repository setup script. If using an isolated module directory, set `VMODULES`
to that directory before setup and validation.

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

Run from the repository root with the native Vulkan prerequisites installed:

```sh
compiler=${VEXE:-v}
"$compiler" run setup.vsh
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
  "$compiler" run examples/buffer_suballocation
```

Use the pinned current compiler and add `-new-compiler` for the strict V3 run.
To select a specific driver, set `VK_DRIVER_FILES` to an installed ICD manifest
on the current host. Otherwise the Vulkan loader selects the available driver.
