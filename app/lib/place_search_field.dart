// A text box that looks up real stops/places as someone types, and shows
// them as tappable suggestions underneath - the "type a name, not a
// number" search box. Shared by journey_screen.dart and by_hour_screen.dart
// (both need "pick a From and a To place"), pulled out here rather than
// duplicated so the debounce/suggestion behaviour only has to be right
// once.

import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';

/// Waits this long after the last keystroke before asking the backend, so
/// typing a whole word doesn't fire one request per letter.
const _debounceDelay = Duration(milliseconds: 350);

class PlaceSearchField extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<PlaceSuggestion> onPicked;

  const PlaceSearchField({
    super.key,
    required this.label,
    required this.controller,
    required this.onPicked,
  });

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    // Hide suggestions once the field isn't focused any more - otherwise
    // they'd linger on screen after someone taps elsewhere.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && mounted) {
        setState(() => _suggestions = []);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () async {
      setState(() => _searching = true);
      final results = await searchPlaces(text);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searching = false;
      });
    });
  }

  void _pick(PlaceSuggestion place) {
    widget.controller.text = place.stopName;
    setState(() => _suggestions = []);
    widget.onPicked(place);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            labelText: '${widget.label} (type a stop or place name)',
            isDense: true,
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: _onChanged,
        ),
        if (_suggestions.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final place in _suggestions)
                  ListTile(
                    dense: true,
                    title: Text(place.stopName),
                    onTap: () => _pick(place),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
