import 'package:flutter/widgets.dart';

class AiDebugTarget extends StatelessWidget {
  const AiDebugTarget({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    return Semantics(identifier: id, child: child);
  }
}
