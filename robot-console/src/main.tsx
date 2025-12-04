import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.scss";
import "@polyflowrobotics/ui-components/style.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root container missing in index.html");
}

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
