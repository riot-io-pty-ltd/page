package app.page.android.testkit;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Random;
import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import javax.imageio.ImageWriter;

/** Pictures made, encoded and decoded with ImageIO, for the photo tests. ImageIO writes no EXIF of its own. */
public final class JvmImages {
    private JvmImages() {}

    /** A picture the tests can hold without seeing java.awt. */
    public static final class Img {
        private final BufferedImage image;

        Img(BufferedImage image) { this.image = image; }

        public int width() { return image.getWidth(); }

        public int height() { return image.getHeight(); }

        public int argb(int x, int y) { return image.getRGB(x, y); }

        /** Some pixel is not fully opaque. */
        public boolean hasAlpha() {
            if (!image.getColorModel().hasAlpha()) return false;
            for (int y = 0; y < image.getHeight(); y++)
                for (int x = 0; x < image.getWidth(); x++)
                    if ((image.getRGB(x, y) >>> 24) != 0xFF) return true;
            return false;
        }

        /** Scaled so the long edge is at most longEdge (never enlarged); JPEG is flattened onto white. */
        public byte[] encode(boolean png, int longEdge, int quality) {
            try {
                double scale = Math.min(1.0, (double) longEdge / Math.max(image.getWidth(), image.getHeight()));
                int w = Math.max(1, (int) Math.round(image.getWidth() * scale));
                int h = Math.max(1, (int) Math.round(image.getHeight() * scale));
                BufferedImage out = new BufferedImage(w, h, png ? BufferedImage.TYPE_INT_ARGB : BufferedImage.TYPE_INT_RGB);
                Graphics2D g = out.createGraphics();
                g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
                if (!png) { g.setColor(Color.WHITE); g.fillRect(0, 0, w, h); }
                g.drawImage(image, 0, 0, w, h, null);
                g.dispose();
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                if (png) {
                    ImageIO.write(out, "png", bytes);
                } else {
                    ImageWriter writer = ImageIO.getImageWritersByFormatName("jpeg").next();
                    ImageWriteParam params = writer.getDefaultWriteParam();
                    params.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
                    params.setCompressionQuality(quality / 100f);
                    writer.setOutput(ImageIO.createImageOutputStream(bytes));
                    writer.write(null, new IIOImage(out, null, null), params);
                    writer.dispose();
                }
                return bytes.toByteArray();
            } catch (IOException e) {
                throw new IllegalStateException(e);
            }
        }
    }

    /** A smooth picture with a little noise ([noise] up to 127): it compresses like a photo does, or like static. */
    public static Img photo(int w, int h, long seed, int noise) {
        Random rnd = new Random(seed);
        BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int r = clamp(x * 255 / w + rnd.nextInt(noise * 2 + 1) - noise);
                int g = clamp(y * 255 / h + rnd.nextInt(noise * 2 + 1) - noise);
                int b = clamp((x + y) * 255 / (w + h) + rnd.nextInt(noise * 2 + 1) - noise);
                img.setRGB(x, y, (r << 16) | (g << 8) | b);
            }
        return new Img(img);
    }

    /** The left half clear, the right half opaque blue. */
    public static Img transparent(int w, int h) {
        BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) img.setRGB(x, y, x < w / 2 ? 0x00000000 : (0xFF << 24) | 0x3366CC);
        return new Img(img);
    }

    public static Img decode(byte[] bytes) {
        try {
            BufferedImage img = ImageIO.read(new ByteArrayInputStream(bytes));
            if (img == null) throw new IllegalStateException("not an image ImageIO can read");
            return new Img(img);
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }

    private static int clamp(int v) { return Math.max(0, Math.min(255, v)); }
}
