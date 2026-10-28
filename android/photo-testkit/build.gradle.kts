// Test support only: java.awt (ImageIO) to generate and decode pictures in the app's JVM unit tests. It is a plain
// Java library because the app's unit tests compile against android.jar, which has no java.awt.
plugins {
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
