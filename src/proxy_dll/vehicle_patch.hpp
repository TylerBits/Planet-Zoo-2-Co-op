#pragma once

#include <cstddef>
#include <cstdint>

namespace pz2 {

// Removes or restores the car-specific forced boundary / auto-brake gate inside
// CarPhysicsComponentManager (the 4..25 m lookahead physics sweep and habitat/keep-out
// spatial volume stop/teleport), while leaving real Havok/Cobra rigidbody wall collisions intact.
bool setVehicleForcedBoundariesRemoved(bool remove);
bool isVehicleForcedBoundariesRemoved();

// Installs the XINPUT1_4.dll Ordinal 2 (XInputGetState) passthrough hook used exclusively
// during automated live tests to drive forward throttle deterministically without desktop focus.
void installAutotestInputHook();
void setAutotestDriveThrottle(bool active);

// Pure buffer helper exposed for selftest.cpp: locates the unique CarPhysicsComponentManager
// forced-boundary branch inside [data, data + size) and applies or restores the 6-byte jump patch.
bool patchVehicleBoundsInBuffer(std::uint8_t* data, std::size_t size, bool remove);

} // namespace pz2
