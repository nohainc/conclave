class StudioPasskeyBrowser {
  Future<void> register(String baseUrl, String name) async {
    throw UnsupportedError('Passkeys are available in Studio Web.');
  }

  Future<void> signIn(String baseUrl) async {
    throw UnsupportedError('Passkeys are available in Studio Web.');
  }
}

StudioPasskeyBrowser createStudioPasskeyBrowser() => StudioPasskeyBrowser();
