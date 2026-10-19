import "dart:async";

import "package:flutter/material.dart";
import "package:photos/service_locator.dart";
import "package:photos/theme/ente_theme.dart";

class AutoUnnamedPersonThresholdSetting extends StatefulWidget {
  const AutoUnnamedPersonThresholdSetting({super.key});

  @override
  State<AutoUnnamedPersonThresholdSetting> createState() =>
      _AutoUnnamedPersonThresholdSettingState();
}

class _AutoUnnamedPersonThresholdSettingState
    extends State<AutoUnnamedPersonThresholdSetting> {
  late int _autoUnnamedPersonPhotoThreshold;

  @override
  void initState() {
    super.initState();
    _autoUnnamedPersonPhotoThreshold =
        localSettings.autoUnnamedPersonPhotoThreshold;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = getEnteTextTheme(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Auto-create unnamed people", style: textTheme.smallBold),
          const SizedBox(height: 4),
          Text(
            "Create an unnamed person for an unassigned face cluster after it appears in this many distinct uploaded photos. Applied on the next normal ML run or manual clustering command. Set to 0 to disable.",
            style: textTheme.miniMuted,
          ),
          Slider(
            value: _autoUnnamedPersonPhotoThreshold.toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            label: _autoUnnamedPersonPhotoThreshold == 0
                ? "Off"
                : "$_autoUnnamedPersonPhotoThreshold photos",
            onChanged: (value) {
              final threshold = value.round();
              setState(() => _autoUnnamedPersonPhotoThreshold = threshold);
              unawaited(
                localSettings.setAutoUnnamedPersonPhotoThreshold(threshold),
              );
            },
          ),
          Text(
            _autoUnnamedPersonPhotoThreshold == 0
                ? "Current: Off"
                : "Current: $_autoUnnamedPersonPhotoThreshold photos",
            style: textTheme.miniMuted,
          ),
          const SizedBox(height: 4),
          Text("Default: 10 photos", style: textTheme.miniMuted),
        ],
      ),
    );
  }
}
