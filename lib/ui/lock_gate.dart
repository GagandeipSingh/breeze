import 'dart:ui' show BoxWidthStyle;
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'glass_chrome.dart';
import 'glass_surface.dart';
import 'kit.dart';
import 'scale.dart';
import 'sheets.dart' show showToast;

/// The one door every lock goes through: locking, unlocking, opening,
/// sharing or deleting a locked file.
///
/// Two ways to prove it is you, tried in this order:
/// 1. The phone's own lock (fingerprint, face, PIN, pattern, password).
/// 2. A Breeze PIN, for a phone with NO screen lock, the way Google Files'
///    Safe folder works. It is made the first time something is locked on
///    such a phone, and only its salted hash is stored.
///
/// Every path fails CLOSED: a cancel, an error or no way to check keeps the
/// file shut. A Breeze PIN is only ever offered while LOCKING something, never
/// at an unlock prompt, so removing the screen lock does not let anyone make
/// a PIN to walk into files that are already locked.

/// Whether the phone has a screen lock Breeze can ask for.
Future<bool> hasScreenLock() async {
  try {
    return await LocalAuthentication().isDeviceSupported();
  } catch (_) {
    return false;
  }
}

// -- Breeze PIN ---------------------------------------------------------

const _kPin = 'pin'; // "salt:hash", one key so it can never be half-written
const _kFails = 'pin_fails';
const _kUntil = 'pin_wait_until';
const _kLast = 'pin_last_fail';
const _kWait = 'pin_wait_secs';
const _kUpUntil = 'pin_wait_up_until';
const _kUpAt = 'pin_last_fail_up';

/// Milliseconds since the phone started, or null (no channel, as in tests).
Future<int?> _uptime() async {
  try {
    return await const MethodChannel('breeze/open').invokeMethod<int>('uptime');
  } catch (_) {
    return null;
  }
}

const _pinMin = 4;
const _pinMax = 8;

/// Whether a Breeze PIN has been made.
Future<bool> hasBreezePin() async {
  final prefs = await SharedPreferences.getInstance();
  await _migrate(prefs);
  return prefs.getString(_kPin) != null;
}

/// A PIN saved by the first build (salt and hash in two keys) moves into
/// the single key.
Future<void> _migrate(SharedPreferences prefs) async {
  final salt = prefs.getString('pin_salt');
  final hash = prefs.getString('pin_hash');
  if (salt != null && hash != null && prefs.getString(_kPin) == null) {
    await prefs.setString(_kPin, '$salt:$hash');
  }
  if (salt != null || hash != null) {
    await prefs.remove('pin_salt');
    await prefs.remove('pin_hash');
  }
}

Future<String> _hashAsync(String salt, String pin) =>
    Isolate.run(() => _hash(salt, pin));

String _hash(String salt, String pin) {
  // Stretched, so the hash cannot be brute-forced instantly off a copied
  // prefs file (a 4-digit PIN is only 10,000 guesses).
  List<int> d = utf8.encode('$salt:$pin');
  for (var i = 0; i < 20000; i++) {
    d = sha256.convert(d).bytes;
  }
  return base64.encode(d);
}

Future<void> _savePin(String pin) async {
  final prefs = await SharedPreferences.getInstance();
  final r = Random.secure();
  final salt = base64.encode(List.generate(16, (_) => r.nextInt(256)));
  final hash = await _hashAsync(salt, pin);
  await prefs.setString(_kPin, '$salt:$hash');
  await _clearWait(prefs);
}

Future<void> _clearWait(SharedPreferences prefs) async {
  await prefs.remove(_kFails);
  await prefs.remove(_kUntil);
  await prefs.remove(_kLast);
  await prefs.remove(_kWait);
  await prefs.remove(_kUpUntil);
  await prefs.remove(_kUpAt);
}

Future<bool> _checkPin(String pin) async {
  final prefs = await SharedPreferences.getInstance();
  await _migrate(prefs);
  final stored = prefs.getString(_kPin);
  final cut = stored?.indexOf(':') ?? -1;
  if (stored == null || cut < 0) return false;
  final ok =
      await _hashAsync(stored.substring(0, cut), pin) ==
      stored.substring(cut + 1);
  if (ok) {
    await _clearWait(prefs);
  } else {
    // Five free tries, then a wait that doubles: 30 s, 1 min, 2 min, …
    // capped at about two hours.
    final fails = (prefs.getInt(_kFails) ?? 0) + 1;
    await prefs.setInt(_kFails, fails);
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(_kLast, now);
    if (fails >= 5) {
      final secs = 30 * (1 << (fails - 5).clamp(0, 8));
      await prefs.setInt(_kWait, secs);
      await prefs.setInt(_kUntil, now + secs * 1000);
      final up = await _uptime();
      if (up != null) {
        await prefs.setInt(_kUpAt, up);
        await prefs.setInt(_kUpUntil, up + secs * 1000);
      } else {
        // An older failure's numbers would time this wait wrongly.
        await prefs.remove(_kUpAt);
        await prefs.remove(_kUpUntil);
      }
    }
  }
  return ok;
}

Future<Duration> _waitLeft() async {
  final prefs = await SharedPreferences.getInstance();
  final until = prefs.getInt(_kUntil) ?? 0;
  final last = prefs.getInt(_kLast) ?? 0;
  final secs = prefs.getInt(_kWait) ?? 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  // Within the same boot, time since boot decides: moving the clock forward
  // used to end the wait at once, so the PIN could be guessed without it.
  final up = secs > 0 ? await _uptime() : null;
  final upAt = prefs.getInt(_kUpAt);
  final upUntil = prefs.getInt(_kUpUntil);
  if (up != null && upAt != null && upUntil != null) {
    if (up < upAt) {
      // The phone restarted during the wait. The clock can't be trusted
      // (it may have been moved while off), so the wait starts again.
      await prefs.setInt(_kUpAt, up);
      await prefs.setInt(_kUpUntil, up + secs * 1000);
      return Duration(seconds: secs);
    }
    final left = (upUntil - up).clamp(0, secs * 1000);
    if (left == 0) {
      // Waited out: a restart later must not start it again. The failure
      // count stays, so the next wait is still longer.
      await prefs.remove(_kWait);
      await prefs.remove(_kUntil);
      await prefs.remove(_kUpAt);
      await prefs.remove(_kUpUntil);
    }
    return Duration(milliseconds: left);
  }
  if (secs > 0 && now < last) {
    // The clock was moved BACK past the last failure: restart the wait from
    // now rather than trust it (and never leave the owner locked out for
    // the size of the jump).
    await prefs.setInt(_kLast, now);
    await prefs.setInt(_kUntil, now + secs * 1000);
    return Duration(seconds: secs);
  }
  final left = until - now;
  // Never longer than the wait that was set: a clock moved forward and then
  // back cannot stretch it, and one moved forward only skips what the cap
  // allows anyway.
  final capped = left.clamp(0, secs * 1000);
  return Duration(milliseconds: capped);
}

// -- the door -------------------------------------------------------------

/// Proves it is the owner: the phone's lock when there is one, otherwise
/// the Breeze PIN. False on a cancel, an error, or no way to check.
Future<bool> authenticate(BuildContext context, String reason) async {
  if (await hasScreenLock()) {
    try {
      return await LocalAuthentication().authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (_) {
      return false;
    }
  }
  if (await hasBreezePin()) {
    if (!context.mounted) return false;
    return await _enterPin(context, reason) ?? false;
  }
  if (context.mounted) await showNoLock(context);
  return false;
}

/// True when a lock can be set: the phone has a screen lock, a Breeze PIN
/// exists, or the user makes one now.
///
/// [anyLocked]: whether anything is ALREADY locked (a file, a trashed file,
/// or "Lock all files"). With no screen lock and no PIN, that lock was made
/// under a screen lock since removed, and creating a PIN now would let
/// whoever holds the phone open those files with it. So it is refused.
Future<bool> ensureCanLock(
  BuildContext context, {
  required bool anyLocked,
}) async {
  if (await hasScreenLock() || await hasBreezePin()) return true;
  if (!context.mounted) return false;
  if (anyLocked) {
    await showNoLock(context);
    return false;
  }
  return await createPin(context) ?? false;
}

/// Make a Breeze PIN (entered twice). True when saved.
Future<bool?> createPin(BuildContext context, {bool change = false}) =>
    _pinSheet(context, mode: change ? _Mode.change : _Mode.create);

/// Change the Breeze PIN: the current one first, then the new one twice.
Future<void> changePin(BuildContext context) async {
  final ok = await _pinSheet(
    context,
    mode: _Mode.enter,
    title: 'Current PIN',
    reason: 'Enter the PIN you use now.',
  );
  if (ok != true || !context.mounted) return;
  final saved = await createPin(context, change: true);
  if (saved == true && context.mounted) {
    showToast(
      context,
      message: 'PIN changed',
      icon: CupertinoIcons.lock_shield,
    );
  }
}

Future<bool?> _enterPin(BuildContext context, String reason) =>
    _pinSheet(context, mode: _Mode.enter, reason: reason);

/// A locked file, but no screen lock and no Breeze PIN to check against:
/// the phone's screen lock was removed after the file was locked.
Future<void> showNoLock(BuildContext context) => showGlassSheet<void>(
  context,
  builder: (ctx) {
    final p = Pal.of(ctx);
    return Padding(
      padding: EdgeInsets.fromLTRB(20.dp, 14.dp, 20.dp, 16.dp),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading(
            p,
            CupertinoIcons.lock_shield,
            'Turn your screen lock back on',
          ),
          SizedBox(height: 8.dp),
          Text(
            'Your screen lock is off. Turn it on in Settings › Security to '
            'open this file. Nothing was deleted.',
            style: TextStyle(color: p.sub, fontSize: 14.sp, height: 1.35),
          ),
          SizedBox(height: 18.dp),
          _Button(p, 'OK', () => Navigator.of(ctx).pop()),
        ],
      ),
    );
  },
);

enum _Mode { enter, create, change }

Future<bool?> _pinSheet(
  BuildContext context, {
  required _Mode mode,
  String? reason,
  String? title,
}) => showGlassSheet<bool>(
  context,
  builder: (_) => _PinSheet(mode: mode, reason: reason, title: title),
);

Future<int> _failCount() async =>
    (await SharedPreferences.getInstance()).getInt(_kFails) ?? 0;

/// Entering or creating the Breeze PIN.
///
/// The UX rules, each from watching it go wrong:
/// - The box clears after EVERY refused try (wrong or blocked), so a new
///   attempt never lands on top of old digits.
/// - The keyboard stays up between tries: submitting does not close it.
/// - A wrong PIN is shown, not shouted: the box shakes once and turns red,
///   and one calm line under it says what happened.
/// - Tries left are counted down before the wait starts, so the wait is
///   never a surprise; during it a live countdown replaces the message and
///   Unlock is disabled instead of refusing taps.
class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.mode, this.reason, this.title});
  final _Mode mode;
  final String? reason;
  final String? title;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  String? _first; // create/change: the PIN typed the first time
  String? _error;
  bool _busy = false;
  bool _show = false; // the eye: PIN visible
  Duration _wait = Duration.zero;
  Timer? _tick;

  bool get _creating => widget.mode != _Mode.enter;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(
      () => setState(() {
        // Typing again clears the red: the mistake has been seen.
        if (_ctrl.text.isNotEmpty && _wait == Duration.zero) _error = null;
      }),
    );
    if (!_creating) _syncWait();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _shake.dispose();
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// Reads the stored wait and, while it lasts, ticks it down every second.
  Future<void> _syncWait() async {
    final w = await _waitLeft();
    if (!mounted) return;
    setState(() => _wait = w);
    _tick?.cancel();
    if (w > Duration.zero) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
        final left = await _waitLeft();
        if (!mounted) return;
        setState(() {
          _wait = left;
          if (left == Duration.zero) _error = null;
        });
        if (left == Duration.zero) {
          _tick?.cancel();
          // After the rebuild: the field is still disabled until then, and a
          // disabled field ignores the request.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focus.requestFocus();
          });
        }
      });
    }
  }

  void _reject(String message) {
    HapticFeedback.mediumImpact();
    setState(() {
      _error = message;
      _ctrl.clear();
    });
    _shake.forward(from: 0);
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    if (_busy || _wait > Duration.zero) return;
    final pin = _ctrl.text;
    if (pin.length < _pinMin) {
      _reject('Use at least $_pinMin digits');
      return;
    }
    if (_creating) {
      if (_first == null) {
        setState(() {
          _first = pin;
          _error = null;
          _ctrl.clear();
        });
        _focus.requestFocus();
      } else if (pin != _first) {
        setState(() => _first = null);
        _reject('Those didn\'t match. Try again.');
      } else {
        setState(() => _busy = true);
        await _savePin(pin);
        if (mounted) Navigator.of(context).pop(true);
      }
      return;
    }
    setState(() => _busy = true);
    final ok = await _checkPin(pin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    // Still busy until the wait is known: a second Done in between would
    // check the same wrong PIN again and count it twice.
    final fails = await _failCount();
    if (!mounted) return;
    final left = 5 - fails;
    _reject(
      left > 0
          ? 'Wrong PIN · $left ${left == 1 ? 'try' : 'tries'} left'
          : 'Wrong PIN',
    );
    await _syncWait();
    if (mounted) setState(() => _busy = false);
  }

  String _clock(Duration d) {
    final s = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    const red = Color(0xFFE5484D);
    final waiting = _wait > Duration.zero;
    final title = !_creating
        ? (widget.title ?? 'Enter Breeze PIN')
        : _first == null
        ? (widget.mode == _Mode.change
              ? 'Choose a new PIN'
              : 'Create a Breeze PIN')
        : 'Confirm your PIN';
    final hint = !_creating
        ? (widget.reason ?? 'Unlock')
        : _first == null
        ? (widget.mode == _Mode.change
              ? '$_pinMin to $_pinMax digits.'
              : 'No screen lock on this phone, so Breeze uses its own PIN. '
                    "It can't be recovered.")
        : 'Enter the same PIN again.';
    final action = _creating && _first == null
        ? 'Next'
        : (_creating ? 'Save' : 'Unlock');
    final canSubmit = !_busy && !waiting && _ctrl.text.length >= _pinMin;

    // One calm status line: countdown while waiting, else the error.
    Widget status;
    if (waiting) {
      status = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.timer, size: 15.dp, color: p.sub),
          SizedBox(width: 6.dp),
          Text(
            'Too many tries. Try again in ${_clock(_wait)}',
            style: TextStyle(
              color: p.sub,
              fontSize: 13.5.sp,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    } else if (_error != null) {
      status = Text(
        _error!,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: red,
          fontSize: 13.5.sp,
          fontWeight: FontWeight.w500,
        ),
      );
    } else {
      status = const SizedBox.shrink();
    }

    final box = AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // Three damped swings, then still.
        final t = _shake.value;
        final dx = sin(t * pi * 6) * (1 - t) * 10;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16.dp),
          border: Border.all(
            color: _error != null && !waiting
                ? red.withValues(alpha: 0.75)
                : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: GlassSurface(
          radius: 16.dp,
          padding: EdgeInsets.symmetric(horizontal: 4.dp, vertical: 6.dp),
          child: TextField(
            selectionWidthStyle: BoxWidthStyle.tight,
            controller: _ctrl,
            focusNode: _focus,
            autofocus: true,
            enabled: !waiting,
            obscureText: !_show,
            obscuringCharacter: '•',
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: _pinMax,
            magnifierConfiguration: TextMagnifierConfiguration.disabled,
            cursorColor: p.accent,
            textAlign: TextAlign.center,
            // onEditingComplete (not onSubmitted) so the keyboard stays up.
            onEditingComplete: _submit,
            style: TextStyle(
              color: p.ink,
              fontSize: 20.sp,
              letterSpacing: 6,
              height: 1.2,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              counterText: '',
              // Eye: hidden by default; shown, it catches a typo while the
              // PIN is being chosen. A same-size spacer on the left keeps the
              // digits centred.
              prefixIcon: SizedBox(width: 44.dp),
              suffixIcon: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _show = !_show),
                child: SizedBox(
                  width: 44.dp,
                  child: Icon(
                    _show ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                    size: 20.dp,
                    color: p.sub,
                  ),
                ),
              ),
              suffixIconConstraints: BoxConstraints(
                minWidth: 44.dp,
                minHeight: 40.dp,
              ),
              prefixIconConstraints: BoxConstraints(
                minWidth: 44.dp,
                minHeight: 40.dp,
              ),
            ),
          ),
        ),
      ),
    );

    return Padding(
      // Extra top room: the lock circle sits centred right under the handle,
      // and without it the two crowd each other.
      padding: EdgeInsets.fromLTRB(20.dp, 18.dp, 20.dp, 16.dp),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 52.dp,
              height: 52.dp,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.accent.withValues(alpha: 0.15),
              ),
              child: Icon(
                CupertinoIcons.lock_fill,
                size: 24.dp,
                color: p.accent,
              ),
            ),
          ),
          SizedBox(height: 12.dp),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.ink,
              fontSize: 18.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6.dp),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.sub, fontSize: 13.5.sp, height: 1.4),
          ),
          SizedBox(height: 18.dp),
          box,
          // Fixed room for the status line, so the buttons never jump.
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: 40.dp),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: KeyedSubtree(
                  key: ValueKey('${_error}_$waiting'),
                  child: status,
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _Button(p, 'Cancel', () {
                  // Not while a PIN is being saved: it would close the sheet
                  // and save the PIN anyway.
                  if (!_busy) Navigator.of(context).pop(false);
                }, filled: false),
              ),
              SizedBox(width: 10.dp),
              Expanded(
                child: _Button(
                  p,
                  _busy ? 'Checking…' : action,
                  _submit,
                  enabled: canSubmit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.p, this.icon, this.text);
  final Pal p;
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 22.dp, color: p.accent),
      SizedBox(width: 10.dp),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: p.ink,
            fontSize: 18.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

class _Button extends StatelessWidget {
  const _Button(
    this.p,
    this.label,
    this.onTap, {
    this.filled = true,
    this.enabled = true,
  });
  final Pal p;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool enabled;
  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: const Duration(milliseconds: 160),
    opacity: enabled ? 1 : 0.45,
    child: GlassPress(
      onTap: enabled ? onTap : () {},
      label: label,
      child: GlassSurface(
        radius: 14.dp,
        thick: true,
        gradient: filled ? p.accentFill : null,
        child: SizedBox(
          height: 48.dp,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: filled ? Colors.white : p.ink,
                fontSize: 15.5.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
