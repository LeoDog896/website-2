export default {
  buildOptions: {
    site: "http://maxniederman.com",
    sitemap: true,
  },
  renderers: [],
  markdownOptions: {
    remarkPlugins: [
      "remark-gfm",
      "remark-slug",
      "remark-math",
      "remark-footnotes",
      "@silvenon/remark-smartypants",
      "remark-gemoji",
    ],
    rehypePlugins: ["rehype-mathjax"],
  },
};
