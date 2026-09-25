import 'package:flutter/material.dart';

import 'cloud_controller.dart';

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
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      createAccount ? 'Create a Memlib account' : 'Sign in to Memlib',
    ),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Keep your folders, stickers and GIFs in sync across devices.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
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
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => submit(),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                message!,
                style: TextStyle(
                  color: confirmationSent
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    createAccount = !createAccount;
                    confirmationSent = false;
                    message = null;
                  }),
            child: Text(
              createAccount
                  ? 'Already have an account? Sign in'
                  : 'New here? Create an account',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : submit,
        child: Text(
          busy
              ? 'Please wait…'
              : createAccount
              ? 'Create account'
              : 'Sign in',
        ),
      ),
    ],
  );
}
