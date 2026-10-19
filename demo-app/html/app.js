(function () {
  const meta = document.getElementById("host-meta");
  const stamp = document.getElementById("build-stamp");
  const productsEl = document.getElementById("products");

  if (meta) {
    meta.textContent =
      "Host: " + location.hostname + " · Port: " + (location.port || "80") +
      " · Path: gold httpd volume";
  }
  if (stamp) {
    stamp.textContent = "demo-app · " + new Date().toISOString().slice(0, 10);
  }

  fetch("api/catalog.json", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (data) {
      const items = (data && data.items) || [];
      if (!items.length) {
        productsEl.textContent = "Catalog empty.";
        return;
      }
      productsEl.innerHTML = "";
      items.forEach(function (item) {
        const card = document.createElement("article");
        card.className = "card";
        card.innerHTML =
          "<div><h3></h3><p></p></div><div class=\"price\"></div>";
        card.querySelector("h3").textContent = item.name;
        card.querySelector("p").textContent = item.blurb;
        card.querySelector(".price").textContent = item.price;
        productsEl.appendChild(card);
      });
    })
    .catch(function () {
      productsEl.textContent = "Could not load api/catalog.json";
    });
})();
