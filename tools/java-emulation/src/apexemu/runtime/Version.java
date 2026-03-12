package apexemu.runtime;

public final class Version implements Comparable<Version> {
  private final int major;
  private final int minor;
  private final int patch;

  public Version(int major, int minor) {
    this(major, minor, 0);
  }

  public Version(int major, int minor, int patch) {
    this.major = major;
    this.minor = minor;
    this.patch = patch;
  }

  public int major() {
    return major;
  }

  public int minor() {
    return minor;
  }

  public int patch() {
    return patch;
  }

  @Override
  public int compareTo(Version other) {
    if (other == null) {
      return 1;
    }
    int majorCmp = Integer.compare(this.major, other.major);
    if (majorCmp != 0) {
      return majorCmp;
    }
    int minorCmp = Integer.compare(this.minor, other.minor);
    if (minorCmp != 0) {
      return minorCmp;
    }
    return Integer.compare(this.patch, other.patch);
  }

  @Override
  public String toString() {
    return major + "." + minor + "." + patch;
  }
}
