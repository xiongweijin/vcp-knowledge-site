(function () {
  var article = document.querySelector(".md-content__inner");
  if (!article || article.querySelector(".vcp-comments")) return;

  var section = document.createElement("section");
  section.className = "vcp-comments";
  section.setAttribute("aria-label", "留言区");

  var title = document.createElement("h2");
  title.id = "comments";
  title.textContent = "留言区";
  section.appendChild(title);

  var script = document.createElement("script");
  script.src = "https://giscus.app/client.js";
  script.setAttribute("data-repo", "xiongweijin/vcp-knowledge-site");
  script.setAttribute("data-repo-id", "R_kgDOSfvpNA");
  script.setAttribute("data-category", "General");
  script.setAttribute("data-category-id", "DIC_kwDOSfvpNM4C9O0-");
  script.setAttribute("data-mapping", "pathname");
  script.setAttribute("data-strict", "0");
  script.setAttribute("data-reactions-enabled", "1");
  script.setAttribute("data-emit-metadata", "0");
  script.setAttribute("data-input-position", "bottom");
  script.setAttribute("data-theme", "preferred_color_scheme");
  script.setAttribute("data-lang", "zh-CN");
  script.setAttribute("crossorigin", "anonymous");
  script.async = true;

  section.appendChild(script);
  article.appendChild(section);
})();
