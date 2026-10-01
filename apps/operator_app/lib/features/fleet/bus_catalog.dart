/// Manufacturers and models commonly used for buses in India. Operators pick
/// from these lists, or choose [customOption] to type their own.
const customOption = 'Other (enter manually)';

const busCatalog = <String, List<String>>{
  'Tata Motors': ['Starbus', 'Starbus Ultra', 'Marcopolo Paradiso', 'LP 913', 'LP 1512', 'Magna', 'Winger'],
  'Ashok Leyland': ['Viking', 'Lynx', 'Oyster', 'Sunshine', 'Cheetah', 'Falcon', 'Gemini'],
  'Eicher (VECV)': ['Skyline Pro', 'Skyline', 'Starline', 'Skyline Pro 3015'],
  'Volvo': ['9400 B9R', '9400 B8R', '9600', '8400'],
  'Mercedes-Benz': ['Tourismo', 'Travego', 'O500 RS'],
  'Scania': ['Metrolink', 'Touring', 'Interlink'],
  'BharatBenz': ['1017', '1217C', '1617', '1624', 'Coach 3523'],
  'Force Motors': ['Traveller', 'Traveller 26', 'Urbania'],
  'Mahindra': ['Tourister', 'Cruzio', 'Cruzio Grande'],
  'Swaraj Mazda': ['Samrat', 'Sartaj', 'Wing', 'Rajdoot'],
  'Isuzu': ['S-Cab', 'Hi-Lander', 'Samurai'],
  'JCBL': ['Pride', 'Optima', 'Luxe'],
  'Prakash': ['Sleeper Coach', 'Semi-Sleeper Coach'],
};

List<String> get manufacturerNames => busCatalog.keys.toList()..sort();

List<String> modelsFor(String manufacturer) => busCatalog[manufacturer] ?? const [];
