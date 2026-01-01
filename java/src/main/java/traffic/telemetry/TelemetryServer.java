package traffic.telemetry;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Simple TCP server that listens for newline-delimited telemetry payloads from the Godot process.
 */
public final class TelemetryServer {

        private final int port;
        private final ExecutorService executor;

        public TelemetryServer(int port) {
                this.port = port;
                this.executor = Executors.newVirtualThreadPerTaskExecutor();
        }

        public void start() throws IOException {
                try (ServerSocket serverSocket = new ServerSocket(port)) {
                        while (true) {
                                Socket client = serverSocket.accept();
                                executor.submit(() -> handleClient(client));
                        }
                } finally {
                        executor.shutdown();
                }
        }

        private void handleClient(Socket client) {
                try (client;
                     BufferedReader reader = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))) {
                        String line;
                        while ((line = reader.readLine()) != null) {
                                TelemetryParser.parse(line).ifPresent(this::logTelemetry);
                        }
                } catch (IOException exception) {
                        System.err.printf("Telemetry client error: %s%n", exception.getMessage());
                }
        }

        private void logTelemetry(CarTelemetry telemetry) {
                System.out.printf(
                        "%s speed=%.2f m/s throttle=%.2f steer=%.2f brake=%.2f rays[m]=%.2f,%.2f,%.2f sweep(angle=%.1f,d=%.2f)%n",
                        Instant.now(),
                        telemetry.speedMetersPerSecond(),
                        telemetry.throttlePosition(),
                        telemetry.steeringPosition(),
                        telemetry.brakePosition(),
                        telemetry.forwardHitMeters(),
                        telemetry.leftHitMeters(),
                        telemetry.rightHitMeters(),
                        telemetry.sweepAngleDegrees(),
                        telemetry.sweepHitMeters());
        }

        public static void main(String[] args) throws IOException {
                        int port = args.length > 0 ? Integer.parseInt(args[0]) : 5050;
                        new TelemetryServer(port).start();
        }
}
