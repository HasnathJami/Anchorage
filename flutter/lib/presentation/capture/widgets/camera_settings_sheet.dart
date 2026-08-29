import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/data/datasources/mock_upload_api.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:flutter/material.dart';

/// What the gear in the top bar opens.
///
/// The reference design puts a settings icon on the camera and shows nothing
/// behind it, so the contents are a judgement call. The rule applied here: a
/// control earns a place on the *preview* only if it is used while composing a
/// shot. Flash and zoom are, and both sit on the preview; turning a
/// composition grid on is not, so it lives here and the preview stays as
/// uncluttered as the reference.
///
/// Flash was briefly listed here as well, as an explicit four-way choice,
/// while the top bar already carried a cycling button for the same setting.
/// Two controls for one setting is two places to look and one to forget, so
/// the list went and the button stayed: it steps through the whole of
/// `FlashPolicy.cycle`, so no mode became unreachable by dropping the list.
///
/// The mock-transport switch is here for the same reason. The brief supplies
/// no API, so the app ships with a scripted one; being able to force a
/// low-bandwidth collapse or a 400 on a real device is how a reviewer sees the
/// retry engine work in seconds instead of by unplugging a router. It is a
/// demonstration affordance, clearly labelled as one, and nothing in the sync
/// engine reads it.
class CameraSettingsSheet extends StatefulWidget {
  const CameraSettingsSheet({
    required this.showsGrid,
    required this.onGridToggled,
    required this.onOpenUploads,
    super.key,
  });

  final bool showsGrid;
  final VoidCallback onGridToggled;
  final VoidCallback onOpenUploads;

  static Future<void> show(
    BuildContext context, {
    required bool showsGrid,
    required VoidCallback onGridToggled,
    required VoidCallback onOpenUploads,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => CameraSettingsSheet(
        showsGrid: showsGrid,
        onGridToggled: onGridToggled,
        onOpenUploads: onOpenUploads,
      ),
    );
  }

  @override
  State<CameraSettingsSheet> createState() => _CameraSettingsSheetState();
}

class _CameraSettingsSheetState extends State<CameraSettingsSheet> {
  late bool _showsGrid = widget.showsGrid;

  /// Two outcomes, because a server has two answers.
  ///
  /// `LOW BANDWIDTH` and `NO INTERNET` used to be here and were removed on
  /// purpose: those are conditions of the *link*, the app now reads them from
  /// the device itself, and a scripted copy of them proved nothing. `hang` is
  /// absent for a different reason — see its doc comment.
  static const Map<MockUploadBehaviour, String> _mockLabels =
      <MockUploadBehaviour, String>{
    MockUploadBehaviour.succeed: 'SUCCESS',
    MockUploadBehaviour.fail: 'FAILED',
  };

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: const BorderRadius.vertical(top: HarborRadius.sheet),
      ),
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.sm,
        HarborSpacing.md,
        HarborSpacing.md,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.textTertiary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: HarborSpacing.sm),
              Text(
                'Capture settings',
                style: text.screenTitle.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: HarborSpacing.lg),

              _SectionLabel('COMPOSITION'),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _showsGrid,
                activeThumbColor: colors.primaryBright,
                title: Text(
                  'Rule-of-thirds grid',
                  style: TextStyle(color: colors.textPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  'A faint 3x3 guide over the preview.',
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
                onChanged: (_) {
                  setState(() => _showsGrid = !_showsGrid);
                  widget.onGridToggled();
                },
              ),

              const SizedBox(height: HarborSpacing.md),
              const _MockTransportSection(labels: _mockLabels),

              const SizedBox(height: HarborSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.onOpenUploads,
                  icon: Icon(Icons.cloud_upload_outlined,
                      size: 18, color: colors.primaryBright),
                  label: Text(
                    'OPEN UPLOAD MANAGER',
                    style: text.button.copyWith(color: colors.primaryBright),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: colors.primaryBright),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(HarborRadius.button),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The canned-response switch over [MockUploadApi].
///
/// Renders nothing at all when the real transport is wired in, so shipping
/// against a live server removes it without touching this file.
class _MockTransportSection extends StatefulWidget {
  const _MockTransportSection({required this.labels});

  final Map<MockUploadBehaviour, String> labels;

  @override
  State<_MockTransportSection> createState() => _MockTransportSectionState();
}

class _MockTransportSectionState extends State<_MockTransportSection> {
  @override
  Widget build(BuildContext context) {
    if (!getIt.isRegistered<MockUploadApi>()) return const SizedBox.shrink();

    final MockUploadApi api = getIt<MockUploadApi>();
    final HarborColors colors = context.harborColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionLabel('MOCK API RESPONSE'),
        const SizedBox(height: HarborSpacing.xxs),
        Text(
          'The brief supplies no server. Choose what the far end says. '
          'Connection loss and low bandwidth are read from the device, not '
          'from here.',
          style: TextStyle(color: colors.textSecondary, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: HarborSpacing.xs),
        Wrap(
          spacing: HarborSpacing.xs,
          runSpacing: HarborSpacing.xs,
          children: widget.labels.entries
              .map(
                (MapEntry<MockUploadBehaviour, String> entry) => _Chip(
                  label: entry.value,
                  selected: api.behaviour == entry.key,
                  onTap: () => setState(() => api.behaviour = entry.key),
                ),
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: context.harborText.eyebrow
          .copyWith(color: context.harborColors.textTertiary),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? colors.primaryGhost : Colors.transparent,
            borderRadius: const BorderRadius.all(HarborRadius.pill),
            border: Border.all(
              color: selected ? colors.primaryBright : colors.hairline,
            ),
          ),
          child: Text(
            label,
            style: context.harborText.eyebrow.copyWith(
              color: selected ? colors.primaryBright : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
