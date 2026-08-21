// Shared error display for journey_screen.dart and by_hour_screen.dart -
// both show either an honest "no route found" or a real request failure,
// and only the second is worth offering to retry (see call sites).

import 'package:flutter/material.dart';

class ErrorCard extends StatelessWidget {
  final String message;
  // Null means "don't offer to retry" - used for the honest "no route
  // found" case, where trying the exact same query again would just ask
  // the same honest question and get the same honest answer.
  final VoidCallback? onRetry;
  const ErrorCard({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onRetry, child: const Text('Try again')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
