/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,

  // LocalStack's CloudFront proxy hands back a decompressed body while still forwarding the
  // origin's `Content-Encoding: gzip` header. Measured through the distribution domain:
  //     curl              -> 200, 5463 bytes
  //     curl --compressed -> curl: (61) incorrect header check, 0 bytes
  // curl never asks for gzip so it ignores the header; a browser always asks and always
  // believes it, fails to decode, and renders a blank page. Not compressing at the origin
  // removes the header, and therefore the mismatch. On real AWS the CDN compresses at the
  // edge, so this costs nothing there.
  compress: false,
}

module.exports = nextConfig
