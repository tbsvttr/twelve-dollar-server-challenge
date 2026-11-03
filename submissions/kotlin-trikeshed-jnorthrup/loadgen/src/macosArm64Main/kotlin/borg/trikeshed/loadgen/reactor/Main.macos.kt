package borg.trikeshed.loadgen.reactor

import borg.trikeshed.userspace.nio.channels.spi.KqueueReactorOperations
import borg.trikeshed.userspace.nio.channels.spi.PosixChannelOperations
import borg.trikeshed.userspace.nio.file.spi.PosixFileOperations
import kotlinx.coroutines.runBlocking
import kotlin.system.exitProcess

/** The macOS client: its context holds the kqueue reactor, POSIX channels and POSIX files. */
fun main(args: Array<String>) {
    val options = args.associate { it.substringBefore('=') to it.substringAfter('=') }
    val pass = runBlocking(PosixChannelOperations() + KqueueReactorOperations() + PosixFileOperations()) { runLoad(options) }
    exitProcess(if (pass) 0 else 1)
}
