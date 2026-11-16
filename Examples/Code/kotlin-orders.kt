package shop

data class Order(val id: Int, val items: List<String>, val total: Double)

sealed interface Result {
    data class Ok(val order: Order) : Result
    data class Failed(val reason: String) : Result
}

class OrderService(private val stock: MutableMap<String, Int>) {
    private var nextId = 1

    fun place(items: List<String>, prices: Map<String, Double>): Result {
        val missing = items.filter { (stock[it] ?: 0) <= 0 }
        if (missing.isNotEmpty()) return Result.Failed("out of stock: ${missing.joinToString()}")
        items.forEach { stock[it] = stock.getValue(it) - 1 }
        return Result.Ok(Order(nextId++, items, items.sumOf { prices[it] ?: 0.0 }))
    }
}

fun main() {
    val service = OrderService(mutableMapOf("tea" to 2, "cake" to 0))
    when (val r = service.place(listOf("tea"), mapOf("tea" to 3.5))) {
        is Result.Ok -> println("order #${r.order.id}: ${r.order.total}")
        is Result.Failed -> println(r.reason)
    }
}
