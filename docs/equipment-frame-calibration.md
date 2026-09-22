# Equipment Frame Calibration

Every swappable pod must publish raw measurements in its own sensor frame, then MotionOS converts vectors into one canonical equipment frame:

```text
+X = equipment forward
+Y = equipment left
+Z = equipment up
```

The transform is stored per **equipment + mount** pair, not globally per sensor.

## Why

A single pod may be mounted:

- lengthwise on a longboard
- rotated 90° on a RipStik platform
- vertically on a bike frame
- on a ski with a different enclosure

Without an explicit transform, comparisons across equipment silently mix coordinate systems.

## Two-pose calibration

M0-B uses a static two-pose calibration:

1. **Level** — equipment stationary and level.
2. **Nose up** — equipment pitched nose-up by a clearly visible angle.

The level gravity vector determines equipment +Z in sensor coordinates.

The nose-up vector resolves rotation about Z. Its horizontal projection points toward equipment -X, allowing construction of a complete right-handed basis.

The result is a proper rotation matrix

```text
R_sensor_to_equipment
```

such that

```text
v_equipment = R_sensor_to_equipment · v_sensor
```

for accelerometer, gyroscope, and magnetometer vectors.

## Calibration receipt

Each equipment profile records:

- equipment ID/type
- mount ID
- rotation matrix
- level mean acceleration
- nose-up mean acceleration
- excitation magnitude
- orthogonality error
- free-form mount notes

## Field acceptance

Reject calibration when:

- the nose-up pose does not create enough angular excitation
- the resulting basis is not orthonormal
- the determinant is not +1
- the mount can move relative to the equipment

The first MetaMotionS field protocol should repeat calibration before and after a ride. A meaningful transform shift indicates mount slip or a non-repeatable mount, not a model problem.
