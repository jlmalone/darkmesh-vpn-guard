#!/usr/bin/env kotlin

import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.system.exitProcess

// Supervise a profile-based client without changing general networking.
// Client arguments and identifiers live in private, per-host configuration.
val stopping = AtomicBoolean(false)
val child = AtomicReference<Process?>(null)
val activeControl = AtomicReference<Process?>(null)
val nice = "/usr/bin/nice"

fun requiredPath(name: String): Path {
    val value = System.getenv(name)?.takeIf { it.isNotBlank() } ?: error("Missing $name")
    return Path.of(value).also { require(it.isAbsolute) { "$name must be absolute" } }
}

fun stopProcess(process: Process) {
    val descendants = process.descendants().toList()
    descendants.forEach { it.destroy() }
    process.destroy()
    if (!process.waitFor(20, TimeUnit.SECONDS)) {
        process.destroyForcibly()
        process.waitFor(5, TimeUnit.SECONDS)
    }
    descendants.filter { it.isAlive }.forEach { it.destroyForcibly() }
}

fun stopClient() { synchronized(child) { child.getAndSet(null) }?.let(::stopProcess) }

Runtime.getRuntime().addShutdownHook(Thread {
    stopping.set(true)
    synchronized(activeControl) { activeControl.getAndSet(null) }?.let(::stopProcess)
    stopClient()
})

data class Result(val code: Int, val output: String)
data class Tunnel(val address: String, val device: String)

fun command(directory: Path, timeout: Long, vararg arguments: String): Result {
    val log = Files.createTempFile(directory, ".profile-control-", ".log")
    try {
        val process = synchronized(activeControl) {
            if (stopping.get()) return Result(130, "Stopping")
            ProcessBuilder(listOf(nice, "-n", "19") + arguments)
                .redirectErrorStream(true).redirectOutput(log.toFile()).start().also { activeControl.set(it) }
        }
        if (!process.waitFor(timeout, TimeUnit.SECONDS)) {
            stopProcess(process)
            return Result(124, "Control command timed out")
        }
        return Result(process.exitValue(), log.toFile().readText().take(65536))
    } finally {
        activeControl.set(null)
        Files.deleteIfExists(log)
    }
}

fun tunnel(directory: Path, control: String): Tunnel? {
    val state = command(directory, 8, control, "get", "connectionstate")
    if (state.code != 0 || state.output.lineSequence().firstOrNull()?.trim() != "Connected") return null
    val routes = command(directory, 8, "/usr/sbin/netstat", "-rn", "-f", "inet")
    if (routes.code != 0) return null
    val devices = routes.output.lineSequence().map { it.trim().split(Regex("\\s+")) }
        .filter { it.firstOrNull() == "0/1" && it.lastOrNull()?.matches(Regex("utun[0-9]+")) == true }
        .map { it.last() }.distinct().toList()
    if (devices.size != 1) return null
    val device = devices.single()
    val iface = command(directory, 8, "/sbin/ifconfig", device)
    if (iface.code != 0) return null
    val address = iface.output.lineSequence().map { it.trim().split(Regex("\\s+")) }
        .firstOrNull { it.firstOrNull() == "inet" }?.getOrNull(1) ?: return null
    if (!address.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}"))) return null
    return Tunnel(address, device)
}

fun runClient(): Int {
    val binary = requiredPath("TRANSFER_CLIENT_BIN")
    val argumentsFile = requiredPath("TRANSFER_CLIENT_ARGUMENTS_FILE")
    val stateDirectory = requiredPath("TRANSFER_CLIENT_STATE_DIR")
    val doctor = System.getenv("TRANSFER_BINDING_TOOL") ?: "/opt/homebrew/bin/transfer-vpn-doctor"
    val control = System.getenv("EXPRESSVPN_CTL") ?: "/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl"
    val processName = System.getenv("TRANSFER_CLIENT_PROCESS") ?: binary.fileName.toString()
    require(processName.matches(Regex("[A-Za-z0-9_.-]{1,15}"))) { "Set a macOS process name of at most 15 characters" }
    require(binary.toFile().canExecute()) { "Configured client is unavailable" }
    require(File(doctor).isAbsolute && File(doctor).canExecute()) { "Binding tool is unavailable" }
    require(File(control).isAbsolute && File(control).canExecute()) { "VPN control tool is unavailable" }
    System.getenv("TRANSFER_CLIENT_RUNTIME_MANIFEST")?.let { manifest ->
        require(Path.of(manifest).isAbsolute) { "Runtime manifest must be absolute" }
        for (line in File(manifest).readLines().filter { it.isNotBlank() }) {
            val columns = line.split('\t', limit = 2)
            require(columns.size == 2 && columns[0].matches(Regex("[0-9a-f]{64}"))) { "Invalid runtime manifest" }
            val library = Path.of(columns[1])
            require(library.isAbsolute) { "Runtime library path must be absolute" }
            val digest = MessageDigest.getInstance("SHA-256")
            Files.newInputStream(library).use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(actual == columns[0]) { "Runtime library changed; rebuild the client before restarting: $library" }
        }
    }
    val arguments = Files.readAllLines(argumentsFile).filter { it.isNotEmpty() }
    require(arguments.isNotEmpty() && arguments.none { '\u0000' in it }) { "Invalid argument file" }
    Files.createDirectories(stateDirectory)
    FileChannel.open(stateDirectory.resolve("profile-launch.lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
        val lock = channel.tryLock() ?: error("Another profile launcher owns this state directory")
        lock.use {
            val initial = tunnel(stateDirectory, control) ?: run {
                System.err.println("VPN tunnel unavailable; client remains stopped")
                return 75
            }
            val running = command(stateDirectory, 8, "/usr/bin/pgrep", "-x", processName)
            if (running.code != 1) {
                System.err.println("Client process already exists or process lookup failed; refusing to edit its profile")
                return 69
            }
            val binding = command(stateDirectory, 45, doctor, "--fix")
            if (binding.code != 0) {
                System.err.println("Client binding refresh refused: ${binding.output}")
                return 69
            }
            val checked = command(stateDirectory, 30, doctor, "--check")
            if (checked.code != 0 || tunnel(stateDirectory, control) != initial) {
                System.err.println("VPN binding did not remain stable; client remains stopped")
                return 75
            }
            val process = synchronized(child) {
                if (stopping.get()) return 0
                ProcessBuilder(listOf(nice, "-n", "19", binary.toString()) + arguments)
                    .inheritIO().start().also { child.set(it) }
            }
            try {
                while (!stopping.get() && process.isAlive) {
                    Thread.sleep(5000)
                    if (tunnel(stateDirectory, control) != initial) {
                        System.err.println("VPN tunnel changed; stopping profile client")
                        stopClient()
                        return 75
                    }
                }
                return process.waitFor()
            } finally { stopClient() }
        }
    }
}

try { exitProcess(runClient()) }
catch (error: Exception) {
    System.err.println("Profile launcher refused startup: ${error.message}")
    stopClient()
    exitProcess(69)
}
