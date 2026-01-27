// Type declarations for static asset imports
// These are handled by Wrangler's module rules at runtime

declare module '*.html' {
  const content: string;
  export default content;
}

declare module '*.png' {
  const content: ArrayBuffer;
  export default content;
}
