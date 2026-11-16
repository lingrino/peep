object Stats {
  final case class Summary(count: Int, mean: Double, max: Double)

  def summarize(xs: Seq[Double]): Option[Summary] =
    if (xs.isEmpty) None
    else Some(Summary(xs.size, xs.sum / xs.size, xs.max))

  def main(args: Array[String]): Unit = {
    val data = Seq(3.5, 1.25, 8.0, 4.75)
    summarize(data) match {
      case Some(Summary(n, mean, max)) => println(f"n=$n mean=$mean%.2f max=$max")
      case None                         => println("no data")
    }
  }
}
