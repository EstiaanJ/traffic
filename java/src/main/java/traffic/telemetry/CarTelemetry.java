package traffic.telemetry;

/**
 * Immutable telemetry sample reported by the Godot driving simulation.
 * Distances use meters and angles use degrees to match the data exported by the Godot side.
 */
public record CarTelemetry(
        double speedMetersPerSecond,
        double throttlePosition,
        double brakePosition,
        double steeringPosition,
        double forwardHitMeters,
        double leftHitMeters,
        double rightHitMeters,
        double sweepAngleDegrees,
        double sweepHitMeters) {
}
