import 'package:flutter/material.dart';

import 'cloud_controller.dart';
import 'theme.dart';

class AccountDialog extends StatefulWidget {
  const AccountDialog({super.key, required this.cloud});
  final CloudController cloud;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool createAccount = false;
  bool busy = false;
  String? message;
  bool confirmationSent = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => message = 'Enter your email and password.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (createAccount) {
        final signedIn = await widget.cloud.signUp(email.text, password.text);
        if (!mounted) return;
        if (signedIn) {
          Navigator.of(context).pop(true);
          return;
        }
        setState(() {
          confirmationSent = true;
          message = 'Check your email to confirm your account, then sign in.';
        });
      } else {
        await widget.cloud.signIn(email.text, password.text);
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BrandMark(size: 40),
              ),
              const SizedBox(height: 18),
              Text(
                createAccount ? 'Create a Memlib account' : 'Sign in to Memlib',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.3,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Keep your folders, stickers and GIFs in sync across devices.',
                style: TextStyle(color: MemlibColors.textMuted, height: 1.4),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline, size: 19),
                ),
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: [
                  createAccount
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline, size: 19),
                ),
                onSubmitted: (_) => submit(),
              ),
              if (message != null)
                Container(
                  margin: const EdgeInsets.only(top: 14),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: confirmationSent
                        ? MemlibColors.accentSoft
                        : MemlibColors.dangerSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    message!,
                    style: TextStyle(
                      fontSize: 13,
                      color: confirmationSent
                          ? MemlibColors.accent
                          : MemlibColors.danger,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: MemlibColors.textMuted,
                        ),
                      )
                    : Text(createAccount ? 'Create account' : 'Sign in'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              createAccount = !createAccount;
                              confirmationSent = false;
                              message = null;
                            }),
                      style: TextButton.styleFrom(
                        foregroundColor: MemlibColors.accent,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      child: Text(
                        createAccount
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
