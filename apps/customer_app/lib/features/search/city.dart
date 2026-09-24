class City {
  final String id;
  final String name;
  final String? state;

  City({required this.id, required this.name, this.state});

  factory City.fromJson(Map<String, dynamic> json) => City(
        id: json['id'] as String,
        name: json['name'] as String,
        state: json['state'] as String?,
      );

  @override
  String toString() => name;
}
