# Hardware Adapter Contract

A hardware adapter has only three jobs:

1. Acquire the vendor's raw measurement and device timestamp.
2. Preserve a monotonically increasing stream sequence number.
3. Emit a `SensorEvent` without changing physical meaning or units.

## Equipment pod

Preferred development capabilities: >=100 Hz 6-axis IMU, monotonic timestamps, BLE, local flash or retransmission, known axis orientation, and a rigid repeatable mount. The adapter should publish `/equipment/imu`.

## Smart insoles

The minimum useful interface is bilateral raw pressure channels + device timestamps. Foot IMU is strongly preferred. Preserve the raw pressure vector even if the vendor also emits center-of-pressure or force estimates.

## Apple Watch

The production watch client should use a workout session for background execution, Core Motion for wrist motion, and HealthKit for allowed physiological/workout data. It should batch-transfer durable samples to the phone while retaining enough state to recover from transient connectivity loss.

## Camera teacher

The phone owns calibration video and pose timestamps. Raw video should be separable from derived joint labels so privacy policy and retention can be configured independently.
