package demo

import kotlin.math.max

/** KDoc */
@JvmInline
value class Id(val raw: Int)

data class User(val name: String, var age: Int = 0) : Base() {
    override fun toString(): String = "User($name, ${age + 1})"
    companion object { const val MAX = 10 }
}

fun <T> List<T>.second(): T? = if (size > 1) this[1] else null

suspend fun main() {
    val users = listOf(User("a"), User("b", 2))
    when (val n = users.size) { 0 -> println("none") else -> println(n * 1.5) }
    users.forEach { println(it.name) }
    val c = 'x'; val b = true; val nul = null
}
