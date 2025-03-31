import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'package:learningpayscreen/succesScreen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:learningpayscreen/cancelScreen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  handleIncomingLinks();
  runApp(const MyApp());
}

late String token;
late String orderId;

bool _hasHandledInitialLink = false;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PayPal Payment',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const PayScreen(),
    );
  }
}

void handleIncomingLinks() {
  final appLinks = AppLinks();

  if (!_hasHandledInitialLink) {
    _hasHandledInitialLink = true;

    appLinks.getInitialAppLink().then((Uri? uri) {
      if (uri != null) {
        print("✅ Initial Deep Link: $uri");
        processLink(uri);
      }
    });

    appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null) {
        print("✅ New Deep Link Triggered: $uri");
        processLink(uri);
      }
    });
  }
}

void processLink(Uri uri) async {
  if (uri.toString().contains("success")) {
    final paymentStatus = await checkPayPalOrderStatus(orderId, token);
    if (paymentStatus == "COMPLETED") {
      print("✅ Payment already completed!");

      navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(builder: (context) => const SuccessScreen()),
      );
    } else if (paymentStatus == "APPROVED") {
      var success = await capturePayPalPayment(token, orderId);

      if (success) {
        print("✅ Payment captured successfully!");

        navigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(builder: (context) => const SuccessScreen()),
        );
      } else {
        print("❌ Payment capture failed.");
      }
    } else {
      print("❌ Unexpected payment status: $paymentStatus");
    }
  } else if (uri.toString().contains("cancel")) {
    print("❌ Payment was canceled by the user.");

    navigatorKey.currentState?.pushReplacement(
      MaterialPageRoute(builder: (context) => const CancelScreen()),
    );
  }
}

Future<String?> checkPayPalOrderStatus(
  String orderId,
  String accessToken,
) async {
  final response = await http.get(
    Uri.parse('https://api-m.sandbox.paypal.com/v2/checkout/orders/$orderId'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode == 200) {
    final jsonData = jsonDecode(response.body);
    final status = jsonData['status'];
    print("✅ Order status: $status");
    return status;
  } else {
    print("❌ Failed to check order status: ${response.body}");
    return null;
  }
}

class PayScreen extends StatelessWidget {
  const PayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Pay Screen")),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          try {
            token = await getPayPalAccessToken();
            orderId = await createPayPalOrder(token);

            final approvalUrl = await getApprovalUrl(token, orderId);
            if (approvalUrl != null) {
              await launchUrl(
                Uri.parse(approvalUrl),
                mode: LaunchMode.externalApplication,
              );
            } else {
              print("❌ Failed to get approval URL.");
            }
          } catch (e) {
            print("❌ Error: $e");
          }
        },
        child: const Icon(Icons.payment),
      ),
    );
  }
}

Future<String> getPayPalAccessToken() async {
  String clientId = dotenv.env["payPal_ClientID"]!;
  String secret = dotenv.env["payPal_SecretKey"]!;

  final basicAuth = 'Basic ${base64Encode(utf8.encode('$clientId:$secret'))}';

  final response = await http.post(
    Uri.parse('https://api-m.sandbox.paypal.com/v1/oauth2/token'),
    headers: {
      'Authorization': basicAuth,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  );

  if (response.statusCode == 200) {
    final jsonData = jsonDecode(response.body);
    return jsonData['access_token'];
  } else {
    throw Exception('❌ Failed to get PayPal access token: ${response.body}');
  }
}

Future<String> createPayPalOrder(String accessToken) async {
  final response = await http.post(
    Uri.parse('https://api-m.sandbox.paypal.com/v2/checkout/orders'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
    body: jsonEncode({
      'intent': 'CAPTURE',
      'purchase_units': [
        {
          'amount': {'currency_code': 'USD', 'value': '10.00'},
        },
      ],
      'application_context': {
        'return_url': 'myapp://success',
        'cancel_url': 'myapp://cancel',
      },
    }),
  );

  if (response.statusCode == 201) {
    final jsonData = jsonDecode(response.body);
    return jsonData['id'];
  } else {
    throw Exception('❌ Failed to create PayPal order: ${response.body}');
  }
}

Future<String?> getApprovalUrl(String accessToken, String orderId) async {
  final response = await http.get(
    Uri.parse('https://api-m.sandbox.paypal.com/v2/checkout/orders/$orderId'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode == 200) {
    final jsonData = jsonDecode(response.body);
    final links = jsonData['links'] as List;
    final approvalLink = links.firstWhere(
      (link) => link['rel'] == 'approve',
      orElse: () => null,
    );
    return approvalLink?['href'];
  } else {
    print("❌ Failed to get approval URL: ${response.body}");
    return null;
  }
}

Future<bool> capturePayPalPayment(String accessToken, String orderId) async {
  final response = await http.post(
    Uri.parse(
      'https://api-m.sandbox.paypal.com/v2/checkout/orders/$orderId/capture',
    ),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
  );

  if (response.statusCode == 201 || response.statusCode == 200) {
    print("✅ Payment Captured Successfully!");
    return true;
  } else {
    print("❌ Failed to capture payment: ${response.body}");
    return false;
  }
}
