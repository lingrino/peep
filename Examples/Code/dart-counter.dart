class Counter {
  int _value = 0;
  final int step;

  Counter({this.step = 1});

  int get value => _value;

  void increment() => _value += step;

  @override
  String toString() => 'Counter($_value, step: $step)';
}

Future<void> main() async {
  final c = Counter(step: 2);
  for (var i = 0; i < 3; i++) {
    c.increment();
  }
  await Future.delayed(const Duration(milliseconds: 10));
  print('$c is ${c.value.isEven ? "even" : "odd"}');
}
