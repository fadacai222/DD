(() => {
  const WINDOWS_URL = 'https://27568.news/DD-Windows.exe';
  const ANDROID_URL = 'https://27568.news/DD-Android.apk';

  const desktopDownloads = document.getElementById('desktopDownloads');
  const singlePlatform = document.getElementById('singlePlatform');
  const singlePlatformHint = document.getElementById('singlePlatformHint');
  const singlePlatformAction = document.getElementById('singlePlatformAction');
  const singlePlatformComing = document.getElementById('singlePlatformComing');
  const singlePlatformName = document.getElementById('singlePlatformName');

  if (!desktopDownloads || !singlePlatform || !singlePlatformAction) {
    return;
  }

  const ua = navigator.userAgent || '';
  const platform = navigator.userAgentData?.platform || navigator.platform || '';
  const coarsePointer = window.matchMedia?.('(pointer: coarse)').matches === true;
  const finePointer = window.matchMedia?.('(pointer: fine)').matches === true;
  const desktopViewport = window.innerWidth >= 900;
  const iPadDesktopMode = /Mac/i.test(platform) && navigator.maxTouchPoints > 1;

  const isAndroid = /Android/i.test(ua);
  const isIOS = /iPhone|iPad|iPod/i.test(ua) || iPadDesktopMode;
  const isMac = !isIOS && /Mac/i.test(platform);

  // PC 优先：大屏 + 鼠标/触控板环境始终展示全部平台。
  // 这样即使浏览器安装了 UA 修改插件，也不会把 Windows PC 误判成 Android 手机。
  const isDesktopLike = desktopViewport && (finePointer || !coarsePointer) && !iPadDesktopMode;

  const showDesktop = () => {
    desktopDownloads.hidden = false;
    singlePlatform.hidden = true;
  };

  const showDownload = ({ hint, url, label }) => {
    desktopDownloads.hidden = true;
    singlePlatform.hidden = false;
    singlePlatformComing.hidden = true;
    singlePlatformAction.hidden = false;
    singlePlatformHint.textContent = hint;
    singlePlatformAction.href = url;
    singlePlatformAction.querySelector('span:last-child').textContent = label;
  };

  const showComingSoon = ({ platformName, hint }) => {
    desktopDownloads.hidden = true;
    singlePlatform.hidden = false;
    singlePlatformAction.hidden = true;
    singlePlatformComing.hidden = false;
    singlePlatformHint.textContent = hint;
    singlePlatformName.textContent = platformName;
  };

  if (isDesktopLike) {
    showDesktop();
    return;
  }

  if (isAndroid) {
    showDownload({
      hint: '已识别为 Android 手机，仅显示当前设备可安装的客户端。',
      url: ANDROID_URL,
      label: '下载 Android APK',
    });
    return;
  }

  if (isIOS) {
    showComingSoon({
      platformName: 'iOS',
      hint: '已识别为 iPhone / iPad，iOS 客户端敬请期待。',
    });
    return;
  }

  if (isMac && coarsePointer) {
    showComingSoon({
      platformName: 'macOS',
      hint: 'macOS 客户端敬请期待。',
    });
    return;
  }

  // 其它无法可靠识别的平台按 PC 处理，避免隐藏用户需要的下载入口。
  showDesktop();

  const windowsLink = desktopDownloads.querySelector('a[href*="DD-Windows.exe"]');
  const androidLink = desktopDownloads.querySelector('a[href*="DD-Android.apk"]');
  if (windowsLink) windowsLink.href = WINDOWS_URL;
  if (androidLink) androidLink.href = ANDROID_URL;
})();
