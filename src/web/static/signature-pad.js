// Signature pad: draws on a <canvas> with pointer events (mouse, pen or touch) and
// copies the drawing as a PNG data URL into the form's hidden "signature" field.
// The form's submit button stays disabled until the guard draws a stroke.
(function () {
  "use strict";

  function setUp(pad) {
    var canvas = pad.querySelector("canvas");
    var field = pad.querySelector('input[name="signature"]');
    var clearButton = pad.querySelector("[data-signature-clear]");
    var form = pad.closest("form");
    var submit = form ? form.querySelector("[data-requires-signature]") : null;
    var ctx = canvas.getContext("2d");
    var drawing = false;
    var hasStroke = false;
    var last = null;

    function reset() {
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.lineWidth = 2.5;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.strokeStyle = "#1f2933";
      hasStroke = false;
      field.value = "";
      if (submit) { submit.disabled = true; }
    }

    function point(event) {
      var rect = canvas.getBoundingClientRect();
      return {
        x: (event.clientX - rect.left) * (canvas.width / rect.width),
        y: (event.clientY - rect.top) * (canvas.height / rect.height)
      };
    }

    canvas.addEventListener("pointerdown", function (event) {
      event.preventDefault();
      canvas.setPointerCapture(event.pointerId);
      drawing = true;
      last = point(event);
      ctx.beginPath();
      ctx.arc(last.x, last.y, ctx.lineWidth / 2, 0, Math.PI * 2);
      ctx.fillStyle = ctx.strokeStyle;
      ctx.fill();
    });

    canvas.addEventListener("pointermove", function (event) {
      if (!drawing) { return; }
      event.preventDefault();
      var next = point(event);
      ctx.beginPath();
      ctx.moveTo(last.x, last.y);
      ctx.lineTo(next.x, next.y);
      ctx.stroke();
      last = next;
      hasStroke = true;
    });

    function finish(event) {
      if (!drawing) { return; }
      drawing = false;
      if (canvas.hasPointerCapture(event.pointerId)) { canvas.releasePointerCapture(event.pointerId); }
      hasStroke = true;
      field.value = canvas.toDataURL("image/png");
      if (submit) { submit.disabled = false; }
    }

    canvas.addEventListener("pointerup", finish);
    canvas.addEventListener("pointercancel", finish);
    clearButton.addEventListener("click", reset);

    if (form) {
      form.addEventListener("submit", function (event) {
        if (!hasStroke || !field.value) {
          event.preventDefault();
          return;
        }
        // Stops a double click from sending the same action twice.
        if (submit) { submit.disabled = true; }
      });
    }

    reset();
  }

  document.querySelectorAll("[data-signature-pad]").forEach(setUp);
})();
