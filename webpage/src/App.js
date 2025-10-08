import React from 'react';
import './App.css';

function App() {
  return (
    <div className="ls-root">
      <main className="ls-container">
        <img src={`${process.env.PUBLIC_URL}/favicon_io/android-chrome-512x512.png`} alt="Local Share" className="ls-logo" />
        <h1 className="ls-title">Local Share</h1>
        <p className="ls-intro">
          Local Share is a lightweight LAN file transfer tool that lets devices on the same network quickly send and receive files.
          Built for simplicity and speed — no accounts, no cloud, just local network transfers.
        </p>

        <div className="ls-buttons">
          <a className="ls-btn ls-btn-android" href="https://github.com/ShayNeeo/localshare/releases/" target="_blank" rel="noopener noreferrer">Android — Download</a>
          <button className="ls-btn ls-btn-ios" disabled>iOS — Coming soon</button>
        </div>

        <footer className="ls-footer">
          <small>Theme: Black & White · Retro font</small>
        </footer>
      </main>
    </div>
  );
}

export default App;
