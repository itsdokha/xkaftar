import 'package:flutter/material.dart';

import '../../state/app_controller.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final displayNameController = TextEditingController();
  bool isLoginMode = true;
  bool _obscurePassword = true;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Kaftar',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isLoginMode ? 'Sign in to continue' : 'Create your account',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compactMeta = constraints.maxWidth < 380;
                          if (compactMeta) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${controller.config.environment}  \u2022  ${controller.config.apiBaseUrl}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF8F98A3),
                                      ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: controller.authInProgress ? null : _showServerCheck,
                                    icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
                                    label: const Text('Check'),
                                  ),
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${controller.config.environment}  \u2022  ${controller.config.apiBaseUrl}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF8F98A3),
                                      ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: controller.authInProgress ? null : _showServerCheck,
                                icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
                                label: const Text('Check'),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: controller.authInProgress
                                  ? null
                                  : () {
                                      setState(() {
                                        isLoginMode = true;
                                      });
                                      controller.clearError();
                                    },
                              style: OutlinedButton.styleFrom(
                                backgroundColor: isLoginMode ? const Color(0xFF171D26) : null,
                              ),
                              child: const Text('Sign in'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: controller.authInProgress
                                  ? null
                                  : () {
                                      setState(() {
                                        isLoginMode = false;
                                      });
                                      controller.clearError();
                                    },
                              style: OutlinedButton.styleFrom(
                                backgroundColor: !isLoginMode ? const Color(0xFF171D26) : null,
                              ),
                              child: const Text('Create account'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF171D26),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF2A3644)),
                        ),
                        child: Text(
                          '\u00A9 Kaftar Messenger 2026. All rights reserved.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFB5C0CB),
                                height: 1.35,
                              ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: emailController,
                        enabled: !controller.authInProgress,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => controller.clearError(),
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined, size: 20),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Enter your email';
                          }
                          if (!value.contains('@') || !value.contains('.')) {
                            return 'Enter a valid email address';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: passwordController,
                        enabled: !controller.authInProgress,
                        obscureText: _obscurePassword,
                        textInputAction: isLoginMode ? TextInputAction.done : TextInputAction.next,
                        onChanged: (_) => controller.clearError(),
                        onFieldSubmitted: isLoginMode ? (_) => _submit() : null,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              size: 20,
                              color: const Color(0xFF8F98A3),
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Enter your password';
                          }
                          if (!isLoginMode && value.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      if (!isLoginMode) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Make sure to remember your password \u2014 you will need it to sign in on other devices.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF8F98A3),
                                height: 1.35,
                              ),
                        ),
                      ],
                      if (!isLoginMode) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: displayNameController,
                          enabled: !controller.authInProgress,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => controller.clearError(),
                          onFieldSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Display name',
                            prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter your display name';
                            }
                            return null;
                          },
                        ),
                      ],
                      if (controller.errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          controller.errorMessage!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFFFF7B7B),
                              ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: controller.authInProgress ? null : _submit,
                        child: controller.authInProgress
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(isLoginMode ? 'Sign in' : 'Create account'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final controller = widget.controller;
    if (isLoginMode) {
      await controller.login(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
      return;
    }
    await controller.register(
      email: emailController.text.trim(),
      password: passwordController.text,
      displayName: displayNameController.text.trim(),
    );
  }

  Future<void> _showServerCheck() async {
    final controller = widget.controller;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Server check'),
          content: FutureBuilder(
            future: controller.checkServerHealth(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  width: 260,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                );
              }
              if (snapshot.hasError) {
                return SizedBox(
                  width: 320,
                  child: Text('Request failed\n\n${snapshot.error}'),
                );
              }
              final result = snapshot.data!;
              return SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('URL: ${controller.config.apiBaseUrl}'),
                    const SizedBox(height: 8),
                    Text('Status: ${result.status}'),
                    const SizedBox(height: 8),
                    Text('Environment: ${result.environment}'),
                    const SizedBox(height: 8),
                    Text('Latency: ${result.latencyMs} ms'),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
