// Offline compiler input only; no command encoder or GPU dispatch uses this file.
#include <metal_stdlib>
using namespace metal;

kernel void smoke(device const uint *input [[buffer(0)]],
                  device uint *output [[buffer(1)]],
                  uint index [[thread_position_in_grid]])
{
    output[index] = (input[index] ^ 0x13579bdfu) + index * 17u;
}
