// dsh-to-phone — browser half.
//
// 两件事，都只针对**用户自己那条消息里的文件卡片**（视频 / 文档）：
//   1. 点开：交给电脑上的默认程序（视频 → 播放器、文档 → 对应软件、没有就系统自己弹"选择打开方式"）；
//   2. 视频卡片给一张**首帧缩略图**（不播放），和手机端一致。
//
// 为什么走 DOM 而不是座位（2026-10-21 实测）：
//   · `conversation.user.text` 工厂座位只给 `{text, facts}`，**拿不到附件**；
//   · 用户消息里的文件卡片是 `UserContent` 直接画的 `<span title=名字>`，没有座位
//     （图片有 `conversation.chat.user.images`，文件没有）。
//   ⇒ 本插件用 MutationObserver 给这些卡片补行为（不改 dsh 本体、不碰它的包）。
//
// 稳定钩子（别改）：容器 `[data-message-attachments]`（宿主显式写的 data 属性），卡片带 `title`。
window.__ModuleLoader__.load({
	id: "dsh-to-phone",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		/**
		 * 配对口的端口**不写死**：每个 dsh 实例各自配置自己的配对端口。
		 * host 半边在本 dsh 的网页服务上注册了 `/pair/client-config`，这里同源问一次。
		 */
		let pairingPort = 0;
		function pairBase() {
			return pairingPort > 0 ? `http://127.0.0.1:${pairingPort}` : "";
		}
		function ensurePairingPort() {
			if (pairingPort > 0) return Promise.resolve(pairingPort);
			try {
				return fetch("/pair/client-config", { cache: "no-store" })
					.then((res) => res.json())
					.then((data) => {
						const p = data !== null && Number.isInteger(data.port) ? data.port : 0;
						if (p > 0) pairingPort = p;
						return pairingPort;
					})
					.catch(() => 0);
			} catch (error) {
				return Promise.resolve(0);
			}
		}
		const CSS_ID = "dsh-to-phone-css";

		/** 手机上传过的文件名（决定电脑侧要不要给「保存」）；启动拉一次，之后每分钟刷新 */
		const phoneNames = new Set();
		let phoneNamesAt = 0;

		function refreshPhoneNames(force) {
			const now = Date.now();
			if (!force && now - phoneNamesAt < 60000) return;
			phoneNamesAt = now;
			ensurePairingPort().then((port) => {
				if (port <= 0) return;
				try {
					fetch(`${pairBase()}/pair/phone-uploads`, { cache: "no-store" })
						.then((res) => res.json())
						.then((data) => {
							const names = data !== null && Array.isArray(data.names) ? data.names : [];
							for (const one of names) {
								if (typeof one === "string") phoneNames.add(one);
							}
						})
						.catch(() => {});
				} catch (error) {
					// 忽略
				}
			});
		}

		function phoneUploaded(name) {
			refreshPhoneNames(false);
			return phoneNames.has(name);
		}

		/** 给卡片右上角加一个「保存」（幂等） */
		function addSaveButton(card, onSave) {
			if (card.dataset !== undefined && card.dataset.dtpSave === "1") return;
			if (card.dataset !== undefined) card.dataset.dtpSave = "1";
			const button = document.createElement("button");
			button.type = "button";
			button.className = "dtp-save";
			button.textContent = "保存";
			button.addEventListener("click", (event) => {
				event.preventDefault();
				event.stopPropagation();
				onSave();
			});
			card.appendChild(button);
		}

		/** 文件：用隐藏 iframe 触发下载（`?download=1` 让 host 回 attachment；不跳页、不弹窗） */
		function saveByName(name) {
			ensurePairingPort().then((port) => {
				if (port <= 0) return;
				try {
					const frame = document.createElement("iframe");
					frame.style.display = "none";
					frame.src = `${pairBase()}/pair/media-by-name/${encodeURIComponent(name)}?download=1`;
					document.body.appendChild(frame);
					setTimeout(() => {
						try {
							frame.remove();
						} catch (error) {
							// 忽略
						}
					}, 60000);
				} catch (error) {
					// 忽略
				}
			});
		}

		/** 图片：src 是 blob/data URL，直接取字节另存 */
		function saveImage(img) {
			try {
				const src = img.currentSrc !== undefined && img.currentSrc !== "" ? img.currentSrc : img.src;
				fetch(src).then((res) => res.blob()).then((blob) => {
					const url = URL.createObjectURL(blob);
					const anchor = document.createElement("a");
					anchor.href = url;
					anchor.download = typeof img.alt === "string" && img.alt !== "" ? img.alt : `image-${Date.now()}.png`;
					anchor.click();
					setTimeout(() => URL.revokeObjectURL(url), 5000);
				}).catch(() => {});
			} catch (error) {
				// 忽略
			}
		}

		const VIDEO_EXT = [".mp4", ".m4v", ".mov", ".3gp", ".3g2", ".mkv", ".webm", ".avi", ".ts", ".flv", ".wmv"];

		const CSS = `
[data-message-attachments] > span[title]{cursor:pointer;transition:border-color .12s ease,background-color .12s ease}
[data-message-attachments] > span[title]:hover{border-color:var(--dsw-alias-state-business-primary,rgb(65,118,230))!important;background-color:var(--dsw-alias-interactive-bg-hover,rgba(0,0,0,.03))!important}
[data-message-attachments] > span[title] > .dtp-poster{flex:none;width:40px;height:40px;border-radius:6px;background-color:#eef0f3;background-size:cover;background-position:center}
[data-message-attachments] > *{position:relative}
/* 视频：只有画面，不留文件名/大小，格子也跟着缩（客户 2026-10-21） */
[data-message-attachments] > span.dtp-video-card{width:auto!important;flex:0 0 auto!important;min-height:0!important;padding:4px!important}
[data-message-attachments] > span.dtp-video-card > .dtp-poster{width:120px!important;height:68px!important;border-radius:8px}
.dtp-save{position:absolute;top:4px;right:4px;z-index:3;font-size:11px;line-height:20px;padding:0 8px;border-radius:10px;border:.5px solid var(--dsw-alias-border-l2,rgba(0,0,0,.2));background:var(--dsw-alias-bg-layer-1,#fff);color:var(--dsw-alias-label-secondary,#333);cursor:pointer;opacity:0;transition:opacity .12s ease}
[data-message-attachments] > *:hover > .dtp-save{opacity:1}
`;

		/** 缩略图缓存（按文件名；同一张卡片反复扫不会重复抽帧） */
		const posters = new Map();
		const posterPending = new Set();

		function ensureStyles() {
			try {
				if (document.getElementById(CSS_ID) !== null) return;
				const el = document.createElement("style");
				el.id = CSS_ID;
				el.textContent = CSS;
				document.head.appendChild(el);
			} catch (error) {
				// 测试环境没有 document
			}
		}

		function lowerOf(value) {
			return typeof value === "string" ? value.toLowerCase() : "";
		}

		function isVideoName(name) {
			const lower = lowerOf(name);
			if (lower === "") return false;
			for (const ext of VIDEO_EXT) {
				if (lower.endsWith(ext)) return true;
			}
			return false;
		}

		/** 让 host 打开这个文件。**不要用 window.open**（客户：会跳网页）；后台 fetch 即可。 */
		function openByName(name) {
			if (typeof name !== "string" || name.trim() === "") return;
			ensurePairingPort().then((port) => {
				if (port <= 0) return;
				try {
					fetch(`${pairBase()}/pair/open-by-name/${encodeURIComponent(name)}`, { mode: "no-cors", cache: "no-store" })
						.catch(() => {});
				} catch (error) {
					// 老浏览器没有 fetch 时什么都不做
				}
			});
		}

		/** 取首帧：<video crossOrigin> + canvas → dataURL（host 那边给了 CORS，画布不会脏） */
		function makePoster(name, onReady) {
			if (pairingPort <= 0) {
				posterPending.add(name);
				ensurePairingPort().then((port) => {
					posterPending.delete(name);
					if (port > 0) makePoster(name, onReady);
				}).catch(() => {
					posterPending.delete(name);
				});
				return;
			}
			if (posters.has(name)) {
				onReady(posters.get(name));
				return;
			}
			if (posterPending.has(name)) return;
			posterPending.add(name);
			const video = document.createElement("video");
			video.crossOrigin = "anonymous";
			video.preload = "auto";
			video.muted = true;
			video.playsInline = true;
			video.style.display = "none";
			const fail = () => {
				posterPending.delete(name);
				try {
					video.remove();
				} catch (error) {
					// 忽略
				}
			};
			video.addEventListener("error", fail);
			video.addEventListener("loadeddata", () => {
				const target = Number.isFinite(video.duration) && video.duration > 0.2 ? 0.1 : 0;
				if (target > 0) {
					video.currentTime = target;
					return; // 等 seeked 再画
				}
				draw();
			}, { once: true });
			video.addEventListener("seeked", () => draw(), { once: true });
			const draw = () => {
				try {
					const width = 240;
					const ratio = video.videoWidth > 0 ? video.videoHeight / video.videoWidth : 0.5625;
					const canvas = document.createElement("canvas");
					canvas.width = width;
					canvas.height = Math.max(1, Math.round(width * ratio));
					canvas.getContext("2d").drawImage(video, 0, 0, canvas.width, canvas.height);
					const url = canvas.toDataURL("image/jpeg", 0.8);
					posters.set(name, url);
					onReady(url);
				} catch (error) {
					// 画布被污染 / 解码失败 ⇒ 不给缩略图（保留原图标）
				} finally {
					posterPending.delete(name);
					try {
						video.remove();
					} catch (error) {
						// 忽略
					}
				}
			};
			video.src = `${pairBase()}/pair/media-by-name/${encodeURIComponent(name)}`;
			document.body.appendChild(video);
		}

		/** 给一张文件卡片补"点开"和"视频缩略图"（幂等） */
		function enhance(card) {
			if (card === null || typeof card !== "object") return;
			const name = typeof card.getAttribute === "function" ? card.getAttribute("title") : "";
			if (typeof name !== "string" || name.trim() === "") return;

			if (card.dataset === undefined || card.dataset.dtpOpen !== "1") {
				if (card.dataset !== undefined) card.dataset.dtpOpen = "1";
				card.setAttribute("role", "button");
				card.setAttribute("tabindex", "0");
				card.setAttribute("aria-label", `打开 ${name}`);
				card.addEventListener("click", (event) => {
					event.preventDefault();
					event.stopPropagation();
					openByName(name);
				});
				card.addEventListener("keydown", (event) => {
					if (event.key === "Enter" || event.key === " ") {
						event.preventDefault();
						openByName(name);
					}
				});
			}

			// 客户 2026-10-21 的规则：**谁发的谁那侧不给"保存"，另一侧才给**。
			// 电脑侧只给"手机上传过"的文件配「保存」（名单由 host 记，`/pair/phone-uploads`）。
			if (phoneUploaded(name)) {
				addSaveButton(card, () => saveByName(name));
			}

			if (!isVideoName(name)) return;
			if (card.dataset !== undefined && card.dataset.dtpThumb === "1") return;
			if (card.dataset !== undefined) card.dataset.dtpThumb = "1";
			// 视频卡片：**只留画面**（客户 2026-10-21：电脑侧也别再显示文件名），格子要跟着缩
			card.classList.add("dtp-video-card");
			const icon = card.firstElementChild;
			const poster = document.createElement("span");
			poster.className = "dtp-poster";
			poster.setAttribute("aria-hidden", "true");
			if (icon !== null && icon !== undefined) {
				card.insertBefore(poster, icon);
			} else {
				card.appendChild(poster);
			}
			for (const child of Array.from(card.children)) {
				if (child === poster) continue;
				if (child.classList !== undefined && child.classList.contains("dtp-save")) continue;
				if (typeof child.style === "object") child.style.display = "none";
			}
			makePoster(name, (url) => {
				poster.style.backgroundImage = `url(${url})`;
				if (icon !== null && icon !== undefined && typeof icon.style === "object") {
					icon.style.display = "none";
				}
			});
		}

		function scan(root) {
			const scope = root !== null && root !== undefined && typeof root.querySelectorAll === "function" ? root : document;
			for (const row of scope.querySelectorAll("[data-message-attachments]")) {
				for (const card of row.children) {
					const hasTitle = typeof card.hasAttribute === "function" && card.hasAttribute("title");
					if (hasTitle) {
						enhance(card);
						continue;
					}
					// 图片（走宿主自己的图片座位）：**手机发的**才给「保存」——
					// 这边的用户消息基本都来自手机；电脑自己贴的图没有"手机上传"记录，也不该给。
					const img = typeof card.querySelector === "function" ? card.querySelector("img") : null;
					if (img !== null && img !== undefined) {
						const label = typeof img.alt === "string" && img.alt !== "" ? img.alt : "";
						if (label === "" || phoneUploaded(label)) {
							addSaveButton(card, () => saveImage(img));
						}
					}
				}
			}
		}

		let approvalControl = null;
		function sendApprovalResult(id, ok, reason) {
			try {
				if (approvalControl !== null && approvalControl.readyState === 1) {
					approvalControl.send(JSON.stringify({ type: "approval/click-result", id: id, ok: ok, reason: reason }));
				}
			} catch (error) {
				// 忽略
			}
		}
		function clickApproval(id, decision) {
			const want = decision === "allowed-once" ? "允许一次" : "拒绝";
			try {
				const all = Array.from(document.querySelectorAll("button, [role=button], span, div"));
				const hit = all.find((el) => (el.textContent || "").trim() === want &&
					el.offsetParent !== null && typeof el.click === "function");
				if (hit === undefined) {
					sendApprovalResult(id, false, "not-found");
					return;
				}
				hit.click();
				sendApprovalResult(id, true, "");
			} catch (error) {
				sendApprovalResult(id, false, "click-failed");
			}
		}
		function ensureApprovalControl() {
			if (approvalControl !== null || pairingPort <= 0) return;
			try {
				const ws = new WebSocket(`ws://127.0.0.1:${pairingPort}/pair/approvals`);
				approvalControl = ws;
				ws.onopen = () => {
					try { ws.send(JSON.stringify({ type: "hello", role: "web" })); } catch (error) {}
				};
				ws.onmessage = (event) => {
					try {
						const message = JSON.parse(event.data);
						if (message !== null && message.type === "approval/click") {
							clickApproval(String(message.id || ""), String(message.decision || "rejected"));
						}
					} catch (error) {}
				};
				ws.onclose = () => {
					approvalControl = null;
					setTimeout(ensureApprovalControl, 5000);
				};
				ws.onerror = () => {};
			} catch (error) {
				approvalControl = null;
			}
		}
		exports.inject = [];
		exports.apply = function apply(ctx) {
			ensureStyles();
			ensurePairingPort().then(() => {
				ensureApprovalControl();
				try {
					scan(document);
					const observer = new MutationObserver(() => scan(document));
					observer.observe(document.body, { childList: true, subtree: true });
				} catch (error) {
					// 非浏览器环境（测试）忽略
				}
			}).catch(() => {});
		};

		return module.exports;
	}
});

