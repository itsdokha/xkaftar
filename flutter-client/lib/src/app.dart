import 'package:flutter/material.dart';

import 'core/app_config.dart';
import 'core/app_theme.dart';
import 'services/token_store.dart';
import 'state/app_controller.dart';
import 'ui/screens/auth_screen.dart';
import 'ui/screens/workspace_screen.dart';

class KaftarApp extends StatefulWidget {
  const KaftarApp({super.key});

  @override
  State<KaftarApp> createState() => _KaftarAppState();
}

class _KaftarAppState extends State<KaftarApp> {
  late final AppController controller;

  @override
  void initState() {
    super.initState();
    controller = AppController(
      config: AppConfig.fromEnvironment(),
      tokenStore: const TokenStore(),
    );
    controller.initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'Kaftar',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: controller.bootstrapInProgress
              ? _BootstrapScreen(environment: controller.config.environment)
              : controller.isAuthenticated
                    ? WorkspaceScreen(controller: controller)
                    : AuthScreen(controller: controller),
        );
      },
    );
  }
}

class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen({required this.environment});

  final String environment;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(strokeWidth: 2.8),
            ),
            const SizedBox(height: 18),
            Text(
              'Kaftar',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              environment,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
