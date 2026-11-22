/** Never let a sign-in link redirect credentials or navigation to another origin. */
export function signInReturnPath(value: string | null): string {
  if (
    !value ||
    !value.startsWith('/') ||
    value.startsWith('//') ||
    /[\\\u0000-\u001f\u007f]/.test(value)
  )
    return '/preview/home';
  try {
    const parsed = new URL(value, 'https://diary.invalid');
    return parsed.origin === 'https://diary.invalid' &&
      (parsed.pathname === '/preview' || parsed.pathname.startsWith('/preview/'))
      ? parsed.pathname + parsed.search + parsed.hash
      : '/preview/home';
  } catch {
    return '/preview/home';
  }
}
