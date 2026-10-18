import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../monetization/age.dart';
import '../../monetization/monetization.dart';

/// First-launch age question: a plain birth-year field.
///
/// It is a neutral age screen in the FTC's sense: it asks for the year
/// with no default, doesn't say which answers matter or what changes, and
/// can't be revisited to try another answer
/// (https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions,
/// and Google Play's Families policy on neutral age screens,
/// https://support.google.com/googleplay/android-developer/answer/9893335).
class AgeScreen extends StatefulWidget {
  const AgeScreen({super.key});

  @override
  State<AgeScreen> createState() => _AgeScreenState();
}

class _AgeScreenState extends State<AgeScreen> {
  final _controller = TextEditingController();
  String? _error;

  void _submit() {
    final year = int.tryParse(_controller.text.trim());
    if (year == null ||
        year < earliestBirthYear ||
        year > DateTime.now().year) {
      setState(() => _error = 'Please enter a four-digit year.');
      return;
    }
    MonetizationScope.read(context).setBirthYear(year);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(Icons.memory, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Welcome',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: InputDecoration(
                    labelText: 'What year were you born?',
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _submit, child: const Text('Continue')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
