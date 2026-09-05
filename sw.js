/* STEL Weed ID.
   The page is fetched fresh whenever there is signal so updates land straight
   away. The chemical data is cached hard — that is the whole point, so a weed
   can be looked up and its product list read standing in a paddock with no
   bars. Label PDFs are not cached here: elabels.apvma.gov.au sends no CORS
   headers, so they open in the browser and the browser caches them. */
var CACHE = "stel-weed-v3";
var FILES = [
  "./",
  "./index.html",
  "./favicon.png",
  "./manifest.webmanifest",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-maskable.png",
  "./data/targets.json",
  "./data/byhost.json",
  "./data/products.json",
  "./data/situations.json",
  "./data/index.json",
  "./data/meta.json"
];

self.addEventListener("install", function(e){
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(function(c){
      return Promise.all(FILES.map(function(f){
        return c.add(new Request(f, {cache: "reload"})).catch(function(){});
      }));
    })
  );
});

self.addEventListener("activate", function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.map(function(k){ return k === CACHE ? null : caches.delete(k); }));
    }).then(function(){ return self.clients.claim(); })
  );
});

function isPage(req){
  return req.mode === "navigate" || (req.headers.get("accept") || "").indexOf("text/html") > -1;
}

self.addEventListener("fetch", function(e){
  if(e.request.method !== "GET") return;
  var url = new URL(e.request.url);

  /* never touch the identification API or the APVMA label host */
  if(url.hostname.indexOf("plantnet.org") > -1 || url.hostname.indexOf("apvma.gov.au") > -1) return;

  /* the page: network first, so the latest version lands whenever there is signal */
  if(isPage(e.request)){
    e.respondWith(
      fetch(e.request).then(function(res){
        if(res && res.status === 200){
          var copy = res.clone();
          caches.open(CACHE).then(function(c){ c.put("./index.html", copy); });
        }
        return res;
      }).catch(function(){
        return caches.match("./index.html").then(function(hit){
          return hit || caches.match("./");
        });
      })
    );
    return;
  }

  /* the data: cache first and keep it. detail.json and hosts.json are not
     precached — they land here the first time a product detail is opened, and
     stay cached from then on. */
  if(url.origin === self.location.origin && url.pathname.indexOf("/data/") > -1){
    e.respondWith(
      caches.match(e.request).then(function(hit){
        if(hit) return hit;
        return fetch(e.request).then(function(res){
          if(res && res.status === 200){
            var copy = res.clone();
            caches.open(CACHE).then(function(c){ c.put(e.request, copy); });
          }
          return res;
        });
      })
    );
    return;
  }

  /* Google Fonts: cached copy first, refreshed quietly behind the scenes */
  if(url.hostname.indexOf("fonts.g") === 0){
    e.respondWith(
      caches.open(CACHE).then(function(c){
        return c.match(e.request).then(function(hit){
          var net = fetch(e.request).then(function(res){
            if(res && res.status === 200) c.put(e.request, res.clone());
            return res;
          }).catch(function(){ return hit; });
          return hit || net;
        });
      })
    );
    return;
  }

  /* icons and the rest: cache first, they rarely change */
  e.respondWith(
    caches.match(e.request).then(function(hit){
      if(hit) return hit;
      return fetch(e.request).then(function(res){
        if(res && res.status === 200 && url.origin === self.location.origin){
          var copy = res.clone();
          caches.open(CACHE).then(function(c){ c.put(e.request, copy); });
        }
        return res;
      });
    })
  );
});
