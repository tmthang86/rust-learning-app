import 'package:flutter/material.dart';

import 'code_editor.dart';

const _sample = '''fn main() {
    let name = "Rustacean";
    println!("Hello, {name}!");
}''';

/// Free-form editor for trying out any Rust code.
class PlaygroundScreen extends StatelessWidget {
  const PlaygroundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playground')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: const [CodeEditor(initialCode: _sample, minLines: 16)],
          ),
        ),
      ),
    );
  }
}
