package traffic.telemetry;

import java.util.Arrays;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

/**
 * Parses single-line telemetry payloads emitted by the Godot car controller.
 * The line format is a set of {@code key=value} pairs separated by {@code |} characters.
 */
public final class TelemetryParser {

        private TelemetryParser() {
        }

        public static Optional<CarTelemetry> parse(String line) {
                if (line == null || line.isBlank()) {
                        return Optional.empty();
                }

                Map<String, String> values = Arrays.stream(line.strip().split("\\|"))
                        .map(TelemetryParser::splitPair)
                        .filter(entry -> entry.length == 2)
                        .collect(Collectors.toUnmodifiableMap(entry -> entry[0], entry -> entry[1], (left, right) -> right));

                return Optional.of(new CarTelemetry(
                        parseDouble(values.get("speed_mps")),
                        parseDouble(values.get("throttle")),
                        parseDouble(values.get("brake")),
                        parseDouble(values.get("steering")),
                        parseDouble(values.get("forward_hit_m")),
                        parseDouble(values.get("left_hit_m")),
                        parseDouble(values.get("right_hit_m")),
                        parseDouble(values.get("sweep_angle_deg")),
                        parseDouble(values.get("sweep_hit_m"))));
        }

        private static double parseDouble(String raw) {
                if (raw == null || raw.isBlank()) {
                        return Double.NaN;
                }
                try {
                        return Double.parseDouble(raw);
                } catch (NumberFormatException ignored) {
                        return Double.NaN;
                }
        }

        private static String[] splitPair(String pair) {
                int delimiter = pair.indexOf('=');
                if (delimiter < 0) {
                        return new String[]{pair};
                }
                return new String[]{pair.substring(0, delimiter), pair.substring(delimiter + 1)};
        }
}
