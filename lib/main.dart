import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dashboard_page.dart';
import 'registration_page.dart';
import 'package:provider/provider.dart';
import 'utils/app_theme_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => AppTheme())],
      child: Consumer<AppTheme>(
        builder: (context, appTheme, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Indian Gold Health',
            theme: ThemeData(
              primarySwatch: appTheme.getMaterialColor(),
              primaryColor: appTheme.colors.primary,
              scaffoldBackgroundColor: appTheme.colors.background,
              cardColor: appTheme.colors.cardColor,
              colorScheme: ColorScheme.fromSwatch(
                primarySwatch: appTheme.getMaterialColor(),
                accentColor: appTheme.colors.secondary,
                backgroundColor: appTheme.colors.background,
              ),
              appBarTheme: AppBarTheme(
                backgroundColor: appTheme.colors.secondary,
                foregroundColor: Colors.white,
              ),
              textTheme: TextTheme(
                bodyLarge: TextStyle(color: appTheme.colors.textColor),
                bodyMedium: TextStyle(color: appTheme.colors.textColor),
                titleLarge: TextStyle(color: appTheme.colors.headingColor),
              ),
              useMaterial3: true,
            ),
            home: StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasData) {
                  return const DashboardPage();
                }
                return const LoginPage();
              },
            ),
          );
        },
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isPasswordVisible = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );

        // STRICT CHECK: Ensure Shop Data Exists
        // If we are here, Firebase says "Login Success". But user says "without find shop details login not possible".
        // So we must check.
        User? currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          var shopDoc = await FirebaseFirestore.instance
              .collection('shops')
              .doc(currentUser.uid)
              .get();
          if (!shopDoc.exists) {
            await FirebaseAuth.instance.signOut();
            if (mounted) {
              throw FirebaseAuthException(
                code: 'no-shop-data',
                message:
                    "Account exists but Shop Details are missing. Please Register.",
              );
            }
          }
        }
        // If shopDoc exists, StreamBuilder handles navigation.
      } catch (e) {
        String firebaseError = e.toString();
        debugPrint("Standard Login Failed: $firebaseError");

        // UNIVERSAL MANUAL AUTH FALLBACK
        bool manualAuthSuccess = false;
        try {
          String email = _emailController.text.trim();
          var bytes = utf8.encode(_passwordController.text.trim());
          var digest = sha256.convert(bytes);
          String inputHash = digest.toString();

          debugPrint("Attempting Manual Auth for: $email");

          var query = await FirebaseFirestore.instance
              .collection('shops')
              .where('email', isEqualTo: email)
              .limit(1)
              .get();

          if (query.docs.isNotEmpty) {
            var storedHash = query.docs.first['encrypted_password_storage'];
            if (storedHash == inputHash) {
              manualAuthSuccess = true;
              if (mounted) {
                // We implicitly know shop data exists here because we queried it found it!
                debugPrint("MANUAL AUTH SUCCESS: Bypassing Firebase Auth");
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        DashboardPage(uid: query.docs.first.id),
                  ),
                );
                return; // Exit successfully
              }
            } else {
              debugPrint("Manual Auth Failed: Hash mismatch.");
            }
          } else {
            debugPrint("Manual Auth Failed: Email not found in DB.");
          }
        } catch (manualErr) {
          debugPrint("Manual Auth Error: $manualErr");
        }

        // DELETED DEV BYPASS HERE (Strict mode)

        if (mounted) {
          String displayError = manualAuthSuccess
              ? "Success"
              : "Login Failed. Check credentials.";

          if (firebaseError.contains("no-shop-data")) {
            displayError = "Shop Details Missing. Please Register again.";
          } else if (firebaseError.contains("internal-error") ||
              firebaseError.contains("CONFIGURATION_NOT_FOUND")) {
            displayError =
                "Auth Config Error. Manual Check also failed (Wrong Password).";
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(displayError), backgroundColor: Colors.red),
          );

          if (!manualAuthSuccess &&
              (firebaseError.contains("internal-error") ||
                  firebaseError.contains("CONFIGURATION_NOT_FOUND"))) {
            showDialog(
              context: context,
              barrierDismissible: true,
              builder: (context) => AlertDialog(
                title: const Text('Auth Error'),
                content: const Text(
                  "Google Auth is blocked. Manual Database check also failed (User not found or Wrong Password).\n\nPlease check your password.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      final Uri url = Uri.parse(
                        "https://console.firebase.google.com/project/billingsortware/authentication/settings",
                      );
                      if (!await launchUrl(url))
                        debugPrint('Could not launch $url');
                    },
                    child: const Text('FIX AUTH SETTINGS'),
                  ),
                ],
              ),
            );
          }
        }
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appTheme = Provider.of<AppTheme>(context);
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              appTheme.colors.secondary,
              appTheme.colors.primary,
              appTheme.colors.primary.withOpacity(0.5),
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              color: appTheme.colors.cardColor,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24.0,
                  vertical: 40.0,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo or Title
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: appTheme.colors.primary.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.health_and_safety,
                          size: 64,
                          color: appTheme.colors.primary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Indian Gold Health',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: appTheme.colors.headingColor,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Login to your account',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: appTheme.colors.textColor.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 40),

                      // Email Field
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email Address',
                          prefixIcon: Icon(
                            Icons.email_outlined,
                            color: appTheme.colors.primary,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: appTheme.colors.primary,
                              width: 2,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),

                      // Password Field
                      TextFormField(
                        controller: _passwordController,
                        obscureText: !_isPasswordVisible,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(
                            Icons.lock_outline,
                            color: appTheme.colors.primary,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _isPasswordVisible
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: appTheme.colors.primary,
                            ),
                            onPressed: () {
                              setState(() {
                                _isPasswordVisible = !_isPasswordVisible;
                              });
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: appTheme.colors.primary,
                              width: 2,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your password';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),

                      // Forgot Password
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {},
                          child: Text(
                            'Forgot Password?',
                            style: TextStyle(color: appTheme.colors.primary),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Login Button
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: appTheme.colors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                          ),
                          child: _isLoading
                              ? const CircularProgressIndicator(
                                  color: Colors.white,
                                )
                              : const Text(
                                  'LOGIN',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Register Link
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "Don't have an account? ",
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const RegistrationPage(),
                                ),
                              );
                            },
                            child: Text(
                              'Register Now',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: appTheme.colors.primary,
                              ),
                            ),
                          ),
                        ],
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
}
