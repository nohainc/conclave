(function () {
  'use strict';

  function base64UrlToBytes(value) {
    const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4);
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  function bytesToBase64Url(value) {
    const bytes = new Uint8Array(value);
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  }

  function publicKeyOptions(options) {
    return {
      ...options,
      challenge: base64UrlToBytes(options.challenge),
      user: options.user
        ? { ...options.user, id: base64UrlToBytes(options.user.id) }
        : undefined,
      excludeCredentials: (options.excludeCredentials || []).map((item) => ({
        ...item,
        id: base64UrlToBytes(item.id),
      })),
      allowCredentials: (options.allowCredentials || []).map((item) => ({
        ...item,
        id: base64UrlToBytes(item.id),
      })),
    };
  }

  function registrationResponse(credential) {
    const response = credential.response;
    return {
      id: credential.id,
      rawId: bytesToBase64Url(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: bytesToBase64Url(response.clientDataJSON),
        attestationObject: bytesToBase64Url(response.attestationObject),
        transports: response.getTransports ? response.getTransports() : undefined,
      },
    };
  }

  function authenticationResponse(credential) {
    const response = credential.response;
    return {
      id: credential.id,
      rawId: bytesToBase64Url(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: bytesToBase64Url(response.clientDataJSON),
        authenticatorData: bytesToBase64Url(response.authenticatorData),
        signature: bytesToBase64Url(response.signature),
        userHandle: response.userHandle ? bytesToBase64Url(response.userHandle) : undefined,
      },
    };
  }

  async function request(path, options) {
    const response = await fetch(path, {
      credentials: 'include',
      headers: { accept: 'application/json', 'content-type': 'application/json' },
      ...options,
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.message || body.error || `Passkey request failed (${response.status})`);
    return body;
  }

  window.conclavePasskey = {
    async register(baseUrl, name) {
      const options = await request(`${baseUrl}/auth/passkey/generate-register-options?name=${encodeURIComponent(name)}`, { method: 'GET' });
      const credential = await navigator.credentials.create({ publicKey: publicKeyOptions(options) });
      if (!credential) throw new Error('Passkey registration was cancelled');
      return request(`${baseUrl}/auth/passkey/verify-registration`, { method: 'POST', body: JSON.stringify({ response: registrationResponse(credential), name }) });
    },
    async signIn(baseUrl) {
      const options = await request(`${baseUrl}/auth/passkey/generate-authenticate-options`, { method: 'GET' });
      const credential = await navigator.credentials.get({ publicKey: publicKeyOptions(options) });
      if (!credential) throw new Error('Passkey sign-in was cancelled');
      return request(`${baseUrl}/auth/passkey/verify-authentication`, { method: 'POST', body: JSON.stringify({ response: authenticationResponse(credential) }) });
    },
  };
})();
