class AxPasskeyBrowser {
  Future<void> register(String baseUrl, String name) async {
    throw UnsupportedError('Passkeys are available in Conclave AX Web.');
  }

  Future<void> signIn(String baseUrl) async {
    throw UnsupportedError('Passkeys are available in Conclave AX Web.');
  }
}

AxPasskeyBrowser createAxPasskeyBrowser() => AxPasskeyBrowser();
